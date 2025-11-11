// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @title TimeLockedStakingNFT
 * @notice Accepts ERC20 deposits, locks them for a fixed period and mints an ERC721 position NFT.
 *         Rewards are tracked per lock tier via a NAV accumulator that grows when new rewards are distributed.
 */
contract TimeLockedStakingNFT is ERC721, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------
    error ZeroAddress();
    error InvalidAmount();
    error InvalidLockPeriod();
    error PositionNotFound(uint256 tokenId);
    error UnlockNotReached(uint256 unlockTimestamp, uint256 currentTimestamp);
    error NoActiveShares();
    error RewardSourceNotSet();

    /// -----------------------------------------------------------------------
    /// Types
    /// -----------------------------------------------------------------------

    enum LockPeriod {
        OneDay,
        OneWeek,
        OneMonth
    }

    struct Position {
        uint256 sharesAmount;
        uint256 startTimestamp;
        uint256 unlockTimestamp;
        LockPeriod lockPeriod;
        uint256 entryNav;
    }

    /// -----------------------------------------------------------------------
    /// Storage
    /// -----------------------------------------------------------------------

    IERC20 public immutable stakingToken;
    uint256 public nextTokenId;
    mapping(uint256 => Position) private _positions;
    mapping(LockPeriod => uint256) public totalSharesPerTier;
    mapping(LockPeriod => uint256) public navPerTier;
    mapping(LockPeriod => mapping(uint256 => uint256)) public navPerTierAtSlot;
    mapping(LockPeriod => uint256[]) private _navSlots; // strictly increasing slots recorded on reward distribution
    mapping(LockPeriod => mapping(uint256 => uint256)) public expiredSharesAtSlot;
    mapping(LockPeriod => uint256) public cumulativeExpiredShares;
    mapping(LockPeriod => mapping(uint256 => uint256)) public cumulativeExpiredSharesAtSlot;
    mapping(LockPeriod => uint256) private _lastExpiredSlotUpdated;
    mapping(LockPeriod => uint256) public boostFactorPerTier;
    address public rewardSource;
    uint256 public rewardDust;

    uint256 private constant ONE_DAY = 1 days;
    uint256 private constant ONE_WEEK = 7 days;
    uint256 private constant ONE_MONTH = 4 * ONE_WEEK;
    uint256 private constant PRECISION = 1e18;

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event Deposited(
        address indexed owner,
        uint256 indexed tokenId,
        uint256 amount,
        LockPeriod lockPeriod,
        uint256 startTimestamp,
        uint256 unlockTimestamp
    );

    event Withdrawn(address indexed owner, uint256 indexed tokenId, uint256 amount);
    event RewardSourceUpdated(address indexed newRewardSource);
    event BoostFactorPerTierUpdated(LockPeriod indexed lockPeriod, uint256 indexed boostFactor);
    event RewardsDistributed(
        address indexed caller,
        uint256 amountPulled,
        uint256 totalRewardAccounted,
        uint256 currentSlot,
        uint256 navDeltaDay,
        uint256 navDeltaWeek,
        uint256 navDeltaMonth,
        uint256 dust
    );

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(IERC20 stakingToken_, uint256[] memory boostFactorPerTier_) ERC721("Time Locked Staking Position", "TLS") Ownable(msg.sender) {
        if (address(stakingToken_) == address(0)) {
            revert ZeroAddress();
        }
        stakingToken = stakingToken_;
        navPerTier[LockPeriod.OneDay] = PRECISION;
        navPerTier[LockPeriod.OneWeek] = PRECISION;
        navPerTier[LockPeriod.OneMonth] = PRECISION;
        boostFactorPerTier[LockPeriod.OneDay] = boostFactorPerTier_[0];
        boostFactorPerTier[LockPeriod.OneWeek] = boostFactorPerTier_[1];
        boostFactorPerTier[LockPeriod.OneMonth] = boostFactorPerTier_[2];

        uint256 daySlot = _floorToSlot(LockPeriod.OneDay, block.timestamp);
        uint256 weekSlot = _floorToSlot(LockPeriod.OneWeek, block.timestamp);
        uint256 monthSlot = _floorToSlot(LockPeriod.OneMonth, block.timestamp);

        _lastExpiredSlotUpdated[LockPeriod.OneDay] = daySlot;
        _lastExpiredSlotUpdated[LockPeriod.OneWeek] = weekSlot;
        _lastExpiredSlotUpdated[LockPeriod.OneMonth] = monthSlot;

        cumulativeExpiredSharesAtSlot[LockPeriod.OneDay][daySlot] = 0;
        cumulativeExpiredSharesAtSlot[LockPeriod.OneWeek][weekSlot] = 0;
        cumulativeExpiredSharesAtSlot[LockPeriod.OneMonth][monthSlot] = 0;

        _ensureNavCheckpoint(LockPeriod.OneDay, daySlot, PRECISION);
        _ensureNavCheckpoint(LockPeriod.OneWeek, weekSlot, PRECISION);
        _ensureNavCheckpoint(LockPeriod.OneMonth, monthSlot, PRECISION);
    }

    /// -----------------------------------------------------------------------
    /// User actions
    /// -----------------------------------------------------------------------

    /**
     * @notice Lock `amount` of stakingToken and mint a position NFT to `msg.sender`.
     * @param amount The amount of tokens to lock.
     * @param lockPeriod The selected lock tier (1 day, 1 week or 1 month).
     * @return tokenId The id of the minted NFT that represents the locked position.
     */
    function deposit(uint256 amount, LockPeriod lockPeriod) external nonReentrant returns (uint256 tokenId) {
        if (amount == 0) {
            revert InvalidAmount();
        }

        uint256 start = block.timestamp;

        uint256 unlockTime = _ceilToSlot(lockPeriod, block.timestamp);

        tokenId = ++nextTokenId;

        // Determine the NAV applicable for the unlock slot (last checkpoint at or before it)
        uint256 entryNav = _navAtOrBefore(lockPeriod, unlockTime);


        uint256 sharesAmount = Math.mulDiv(amount, PRECISION, entryNav);

        _positions[tokenId] = Position({
            sharesAmount: sharesAmount,
            startTimestamp: start,
            unlockTimestamp: unlockTime,
            lockPeriod: lockPeriod,
            entryNav: entryNav
        });

        totalSharesPerTier[lockPeriod] += sharesAmount;
        expiredSharesAtSlot[lockPeriod][unlockTime] += sharesAmount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        _safeMint(msg.sender, tokenId);

        emit Deposited(msg.sender, tokenId, amount, lockPeriod, start, unlockTime);
    }

    /**
     * @notice Withdraw the locked tokens once the unlock time has passed. Burns the position NFT.
     * @param tokenId The id of the NFT position to redeem.
     */
    function withdraw(uint256 tokenId) external nonReentrant {
        Position memory position = _positions[tokenId];
        if (position.sharesAmount == 0) {
            revert PositionNotFound(tokenId);
        }

        address owner_ = ownerOf(tokenId);
        if (!_isAuthorized(owner_, msg.sender, tokenId)) {
            revert ERC721InsufficientApproval(msg.sender, tokenId);
        }

        uint256 currentTimestamp = block.timestamp;
        if (currentTimestamp < position.unlockTimestamp) {
            revert UnlockNotReached(position.unlockTimestamp, currentTimestamp);
        }

        uint256 unlockSlot = _floorToSlot(position.lockPeriod, position.unlockTimestamp);
        _realizeExpiredSharesUpTo(position.lockPeriod, unlockSlot);
        // Use NAV at or before unlock, and cache it at the unlock slot if missing
        uint256 navAtUnlock = _navAtOrBefore(position.lockPeriod, unlockSlot);
        _ensureNavCheckpoint(position.lockPeriod, unlockSlot, navAtUnlock);

        totalSharesPerTier[position.lockPeriod] -= position.sharesAmount;

        uint256 expiredForSlot = expiredSharesAtSlot[position.lockPeriod][unlockSlot];


        if (expiredForSlot != 0) {
            uint256 amountToRemove = position.sharesAmount;
            if (expiredForSlot < amountToRemove) {
                amountToRemove = expiredForSlot;
            }
            cumulativeExpiredShares[position.lockPeriod] -= amountToRemove;
            cumulativeExpiredSharesAtSlot[position.lockPeriod][unlockSlot] = cumulativeExpiredShares[position.lockPeriod];
            expiredSharesAtSlot[position.lockPeriod][unlockSlot] = expiredForSlot - amountToRemove;
            if (_lastExpiredSlotUpdated[position.lockPeriod] > unlockSlot) {
                _lastExpiredSlotUpdated[position.lockPeriod] = unlockSlot;
            }
        }

        //Function for when we do the  non finish withdraw function.
        //uint256 gain = Math.mulDiv(navAtUnlock - position.entryNav, position.sharesAmount, PRECISION);
        
        uint256 payout = Math.mulDiv(position.sharesAmount, navAtUnlock, PRECISION);

        delete _positions[tokenId];
        _burn(tokenId);

        stakingToken.safeTransfer(owner_, payout);
        emit Withdrawn(owner_, tokenId, payout);
    }

    function distributeRewards(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert InvalidAmount();
        }

        address source = rewardSource;
        if (source == address(0)) {
            revert RewardSourceNotSet();
        }

        uint256 daySlot = _floorToSlot(LockPeriod.OneDay, block.timestamp);
        uint256 weekSlot = _floorToSlot(LockPeriod.OneWeek, block.timestamp);
        uint256 monthSlot = _floorToSlot(LockPeriod.OneMonth, block.timestamp);

        uint256 dayShares = _activeSharesForSlot(LockPeriod.OneDay, daySlot);
        uint256 weekShares = _activeSharesForSlot(LockPeriod.OneWeek, weekSlot);
        uint256 monthShares = _activeSharesForSlot(LockPeriod.OneMonth, monthSlot);

        uint256 dayBoostFactor = boostFactorPerTier[LockPeriod.OneDay];
        uint256 weekBoostFactor = boostFactorPerTier[LockPeriod.OneWeek];
        uint256 monthBoostFactor = boostFactorPerTier[LockPeriod.OneMonth];

        uint256 activeShares = dayShares * dayBoostFactor + weekShares * weekBoostFactor + monthShares * monthBoostFactor;
        if (activeShares == 0) {
            revert NoActiveShares();
        }

        stakingToken.safeTransferFrom(source, address(this), amount);

        uint256 totalReward = amount + rewardDust;
        uint256 distributed;

        uint256 dayNavDelta;
        if (dayShares != 0) {
            uint256 dayReward = Math.mulDiv(totalReward, dayShares * dayBoostFactor, activeShares);
            dayNavDelta = Math.mulDiv(dayReward, PRECISION, dayShares);
            navPerTier[LockPeriod.OneDay] += dayNavDelta;
            _recordNavOnDistribution(LockPeriod.OneDay, daySlot);
            distributed += dayReward;
        }

        uint256 weekNavDelta;
        if (weekShares != 0) {
            uint256 weekReward = Math.mulDiv(totalReward, weekShares * weekBoostFactor, activeShares);
            weekNavDelta = Math.mulDiv(weekReward, PRECISION, weekShares);
            navPerTier[LockPeriod.OneWeek] += weekNavDelta;
            _recordNavOnDistribution(LockPeriod.OneWeek, weekSlot);
            distributed += weekReward;
        }

        uint256 monthNavDelta;
        if (monthShares != 0) {
            uint256 monthReward = Math.mulDiv(totalReward, monthShares * monthBoostFactor, activeShares);
            monthNavDelta = Math.mulDiv(monthReward, PRECISION, monthShares);
            navPerTier[LockPeriod.OneMonth] += monthNavDelta;
            _recordNavOnDistribution(LockPeriod.OneMonth, monthSlot);
            distributed += monthReward;
        }

        rewardDust = totalReward - distributed;

        // Ensure a checkpoint exists for every tier at this slot,
        // even if a given tier received zero delta this round.
        _recordNavOnDistribution(LockPeriod.OneDay, daySlot);
        _recordNavOnDistribution(LockPeriod.OneWeek, weekSlot);
        _recordNavOnDistribution(LockPeriod.OneMonth, monthSlot);

        emit RewardsDistributed(
            msg.sender, amount, totalReward, weekSlot, dayNavDelta, weekNavDelta, monthNavDelta, rewardDust
        );
    }

    function setRewardSource(address newRewardSource) external onlyOwner {
        if (newRewardSource == address(0)) {
            revert ZeroAddress();
        }

        rewardSource = newRewardSource;
        emit RewardSourceUpdated(newRewardSource);
    }
    function setBoostFactorPerTier(LockPeriod lockPeriod, uint256 boostFactor) external onlyOwner {
        boostFactorPerTier[lockPeriod] = boostFactor;
        emit BoostFactorPerTierUpdated(lockPeriod, boostFactor);
    }
    /// -----------------------------------------------------------------------
    /// View helpers
    /// -----------------------------------------------------------------------

    function getPosition(uint256 tokenId) external view returns (Position memory) {
        Position memory position = _positions[tokenId];
        if (position.sharesAmount == 0) {
            revert PositionNotFound(tokenId);
        }
        return position;
    }

    function timeUntilUnlock(uint256 tokenId) external view returns (uint256) {
        Position memory position = _positions[tokenId];
        if (position.sharesAmount == 0) {
            revert PositionNotFound(tokenId);
        }
        if (block.timestamp >= position.unlockTimestamp) {
            return 0;
        }
        return position.unlockTimestamp - block.timestamp;
    }

    function isUnlockable(uint256 tokenId) external view returns (bool) {
        Position memory position = _positions[tokenId];
        if (position.sharesAmount == 0) {
            revert PositionNotFound(tokenId);
        }
        return block.timestamp >= position.unlockTimestamp;
    }

    /// -----------------------------------------------------------------------
    /// Internal logic
    /// -----------------------------------------------------------------------

    function _slotSize(LockPeriod lockPeriod) private pure returns (uint256) {
        if (lockPeriod == LockPeriod.OneDay) {
            return ONE_DAY;
        }
        if (lockPeriod == LockPeriod.OneWeek) {
            return ONE_WEEK;
        }
        if (lockPeriod == LockPeriod.OneMonth) {
            return ONE_MONTH;
        }
        revert InvalidLockPeriod();
    }

    function _floorToSlot(LockPeriod lockPeriod, uint256 timestamp) private pure returns (uint256) {
        uint256 size = _slotSize(lockPeriod);
        return (timestamp / size) * size;
    }

    function _ceilToSlot(LockPeriod lockPeriod, uint256 timestamp) private pure returns (uint256) {
        uint256 size = _slotSize(lockPeriod);
        uint256 slot = ((timestamp + size - 1) / size) * size;
        if (slot == timestamp) {
            slot += size;
        }
        return slot;
    }

    function _ensureNavCheckpoint(LockPeriod lockPeriod, uint256 slot, uint256 navValue) private {
        if (navPerTierAtSlot[lockPeriod][slot] != 0) {
            return;
        }
        navPerTierAtSlot[lockPeriod][slot] = navValue;
        uint256[] storage slots = _navSlots[lockPeriod];
        uint256 len = slots.length;
        if (len == 0 || slots[len - 1] < slot) {
            slots.push(slot);
        }
    }

    function _recordNavOnDistribution(LockPeriod lockPeriod, uint256 slot) private {
        uint256 nextSlot = slot + _slotSize(lockPeriod);
        _ensureNavCheckpoint(lockPeriod, nextSlot, navPerTier[lockPeriod]);
    }

    function _navAtOrBefore(LockPeriod lockPeriod, uint256 slot) private view returns (uint256) {
        // exact match fast-path
        slot = _floorToSlot(lockPeriod, slot);
        uint256 exact = navPerTierAtSlot[lockPeriod][slot];
        if (exact != 0) return exact;
        return _fallbackNavAtOrBefore(lockPeriod, slot);
    }

    // Fallback resolution: find NAV at the latest recorded distribution slot <= target slot
    function _fallbackNavAtOrBefore(LockPeriod lockPeriod, uint256 slot) private view returns (uint256) {
        slot = _floorToSlot(lockPeriod, slot);
        uint256[] storage slots = _navSlots[lockPeriod];
        uint256 len = slots.length;
        if (len == 0) {
            return PRECISION; // no distributions yet
        }
        // if the earliest recorded slot is after the target, baseline
        if (slots[0] > slot) {
            return PRECISION;
        }
        // if the latest recorded slot is before/equal target, take it
        if (slots[len - 1] <= slot) {
            return navPerTierAtSlot[lockPeriod][slots[len - 1]];
        }

        // binary search for greatest index with slots[i] <= slot
        uint256 lo = 0;
        uint256 hi = len - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) >> 1; // bias to the right
            if (slots[mid] <= slot) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return navPerTierAtSlot[lockPeriod][slots[lo]];
    }

    function _realizeExpiredSharesUpTo(LockPeriod lockPeriod, uint256 slot) private {
        uint256 targetSlot = _floorToSlot(lockPeriod, slot);
        uint256 lastSlot = _lastExpiredSlotUpdated[lockPeriod];
        uint256 cumulative = cumulativeExpiredShares[lockPeriod];

        if (targetSlot <= lastSlot) {
            cumulativeExpiredSharesAtSlot[lockPeriod][targetSlot] = cumulative;
            _ensureNavCheckpoint(lockPeriod, targetSlot, navPerTier[lockPeriod]);
            return;
        }

        uint256 size = _slotSize(lockPeriod);
        uint256 current = lastSlot;
        while (current < targetSlot) {
            current += size;
            cumulative += expiredSharesAtSlot[lockPeriod][current];
            cumulativeExpiredSharesAtSlot[lockPeriod][current] = cumulative;
            _ensureNavCheckpoint(lockPeriod, current, navPerTier[lockPeriod]);
        }

        cumulativeExpiredShares[lockPeriod] = cumulative;
        _lastExpiredSlotUpdated[lockPeriod] = targetSlot;
    }

    function _activeSharesForSlot(LockPeriod lockPeriod, uint256 slot) private returns (uint256) {
        uint256 normalizedSlot = _floorToSlot(lockPeriod, slot);
        _realizeExpiredSharesUpTo(lockPeriod, normalizedSlot);

        uint256 total = totalSharesPerTier[lockPeriod];
        uint256 expired = cumulativeExpiredSharesAtSlot[lockPeriod][normalizedSlot];
        if (total > expired) {
            return total - expired;
        }
        return 0;
    }
}
