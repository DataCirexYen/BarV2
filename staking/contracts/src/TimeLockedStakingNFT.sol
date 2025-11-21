// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @title TimeLockedStakingNFT
 * @notice Accepts ERC20 deposits, locks them for a fixed period and mints an ERC721 position NFT.
 *         Rewards are tracked per lock tier via a NAV accumulator that grows when new rewards are distributed.
 *         
 *         MEV Mitigation: This contract uses a "locked profit" model similar to Yearn v2 vaults.
 *         When rewards are distributed, they are added to a tier's locked profit and unlock linearly
 *         over a duration specific to each tier. This prevents MEV bots from capturing value by
 *         depositing right before distributeRewards() and withdrawing immediately after.
 */
contract TimeLockedStakingNFT is ERC721Enumerable, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------
    error ZeroAddress();
    error InvalidAmount();
    error InvalidLockPeriod();
    error PositionNotFound(uint256 tokenId);
    error UnlockNotReached(uint256 unlockTimestamp, uint256 currentTimestamp);
    error EarlyWithdrawUnavailable(uint256 unlockTimestamp, uint256 currentTimestamp);
    error NoActiveShares();
    error RewardSourceNotSet();

    /// -----------------------------------------------------------------------
    /// Types
    /// -----------------------------------------------------------------------

    enum LockPeriod {
        OneWeek,
        OneMonth,
        ThreeMonths,
        TwelveMonths
    }

    struct Position {
        uint256 sharesAmount;
        uint256 startTimestamp;
        uint256 unlockTimestamp;
        LockPeriod lockPeriod;
        uint256 entryNav;
    }

    /**
     * @dev Tracks pending NAV deltas per tier to implement linear reward vesting.
     *      This prevents MEV by ensuring NAV increases unlock gradually over time.
     *      Pure effective NAV model: we track only the effective NAV and pending increases.
     */
    struct TierPendingNav {
        uint256 pendingNavDelta;   // NAV increase (in PRECISION units) pending unlock
        uint256 lastReport;        // Timestamp of last update
        uint256 unlockDuration;    // Duration in seconds over which pendingNavDelta unlocks linearly
    }

    /// -----------------------------------------------------------------------
    /// Storage
    /// -----------------------------------------------------------------------

    IERC20 public immutable stakingToken;
    uint256 public nextTokenId;
    mapping(uint256 => Position) private _positions;
    mapping(LockPeriod => uint256) public totalSharesPerTier;
    mapping(LockPeriod => uint256) public effectiveNavPerTier; // Pure effective NAV (only tracks realized value)
    mapping(LockPeriod => mapping(uint256 => uint256)) public effectiveNavPerTierAtSlot; // Effective NAV checkpoints at each slot
    mapping(LockPeriod => uint256[]) private _navSlots; // strictly increasing slots recorded on reward distribution
    mapping(LockPeriod => mapping(uint256 => uint256)) public expiredSharesAtSlot;
    mapping(LockPeriod => uint256) public cumulativeExpiredShares;
    mapping(LockPeriod => mapping(uint256 => uint256)) public cumulativeExpiredSharesAtSlot;
    mapping(LockPeriod => uint256) private _lastExpiredSlotUpdated;
    mapping(LockPeriod => uint256) public boostFactorPerTier;
    address public rewardSource;
    uint256 public rewardDust;
    
    // Pending NAV tracking per tier (replaces locked profit model)
    mapping(LockPeriod => TierPendingNav) public tierPendingNav;
    
    // Default unlock durations per tier (in seconds)
    uint256 public constant UNLOCK_DURATION_ONE_WEEK = 7 days;
    uint256 public constant UNLOCK_DURATION_ONE_MONTH = 30 days;
    uint256 public constant UNLOCK_DURATION_THREE_MONTHS = 90 days;
    uint256 public constant UNLOCK_DURATION_TWELVE_MONTHS = 365 days;

    uint256 private constant ONE_WEEK = 7 days;
    uint256 private constant FOUR_WEEKS = 4 * ONE_WEEK;
    uint256 private constant TWELVE_WEEKS = 12 * ONE_WEEK;
    uint256 private constant FORTY_EIGHT_WEEKS = 48 * ONE_WEEK;
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
    event EarlyWithdraw(address indexed owner, uint256 indexed tokenId, uint256 payout, uint256 penaltyAmount);
    event RewardSourceUpdated(address indexed newRewardSource);
    event BoostFactorPerTierUpdated(LockPeriod indexed lockPeriod, uint256 indexed boostFactor);
    event RewardsDistributed(
        address indexed caller,
        uint256 amountPulled,
        uint256 totalRewardAccounted,
        uint256 currentSlot,
        uint256 navDeltaWeek,
        uint256 navDeltaMonth,
        uint256 navDeltaThreeMonths,
        uint256 navDeltaTwelveMonths,
        uint256 dust
    );

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(IERC20 stakingToken_) ERC721("Time Locked Staking Position", "TLS") Ownable(msg.sender) {
        if (address(stakingToken_) == address(0)) {
            revert ZeroAddress();
        }
        stakingToken = stakingToken_;
        effectiveNavPerTier[LockPeriod.OneWeek] = PRECISION;
        effectiveNavPerTier[LockPeriod.OneMonth] = PRECISION;
        effectiveNavPerTier[LockPeriod.ThreeMonths] = PRECISION;
        effectiveNavPerTier[LockPeriod.TwelveMonths] = PRECISION;
        boostFactorPerTier[LockPeriod.OneWeek] = 1_050_000_000_000_000_000;
        boostFactorPerTier[LockPeriod.OneMonth] = 1_100_000_000_000_000_000;
        boostFactorPerTier[LockPeriod.ThreeMonths] = 1_200_000_000_000_000_000;
        boostFactorPerTier[LockPeriod.TwelveMonths] = 1_400_000_000_000_000_000;

        uint256 weekSlot = _floorToSlot(LockPeriod.OneWeek, block.timestamp);
        uint256 monthSlot = _floorToSlot(LockPeriod.OneMonth, block.timestamp);
        uint256 threeMonthSlot = _floorToSlot(LockPeriod.ThreeMonths, block.timestamp);
        uint256 twelveMonthSlot = _floorToSlot(LockPeriod.TwelveMonths, block.timestamp);

        _lastExpiredSlotUpdated[LockPeriod.OneWeek] = weekSlot;
        _lastExpiredSlotUpdated[LockPeriod.OneMonth] = monthSlot;
        _lastExpiredSlotUpdated[LockPeriod.ThreeMonths] = threeMonthSlot;
        _lastExpiredSlotUpdated[LockPeriod.TwelveMonths] = twelveMonthSlot;

        cumulativeExpiredSharesAtSlot[LockPeriod.OneWeek][weekSlot] = 0;
        cumulativeExpiredSharesAtSlot[LockPeriod.OneMonth][monthSlot] = 0;
        cumulativeExpiredSharesAtSlot[LockPeriod.ThreeMonths][threeMonthSlot] = 0;
        cumulativeExpiredSharesAtSlot[LockPeriod.TwelveMonths][twelveMonthSlot] = 0;

        _ensureNavCheckpoint(LockPeriod.OneWeek, weekSlot, PRECISION);
        _ensureNavCheckpoint(LockPeriod.OneMonth, monthSlot, PRECISION);
        _ensureNavCheckpoint(LockPeriod.ThreeMonths, threeMonthSlot, PRECISION);
        _ensureNavCheckpoint(LockPeriod.TwelveMonths, twelveMonthSlot, PRECISION);
        
        // Initialize pending NAV unlock durations
        tierPendingNav[LockPeriod.OneWeek].unlockDuration = UNLOCK_DURATION_ONE_WEEK;
        tierPendingNav[LockPeriod.OneMonth].unlockDuration = UNLOCK_DURATION_ONE_MONTH;
        tierPendingNav[LockPeriod.ThreeMonths].unlockDuration = UNLOCK_DURATION_THREE_MONTHS;
        tierPendingNav[LockPeriod.TwelveMonths].unlockDuration = UNLOCK_DURATION_TWELVE_MONTHS;
        
        // Initialize lastReport timestamps
        tierPendingNav[LockPeriod.OneWeek].lastReport = block.timestamp;
        tierPendingNav[LockPeriod.OneMonth].lastReport = block.timestamp;
        tierPendingNav[LockPeriod.ThreeMonths].lastReport = block.timestamp;
        tierPendingNav[LockPeriod.TwelveMonths].lastReport = block.timestamp;
    }

    /// -----------------------------------------------------------------------
    /// User actions
    /// -----------------------------------------------------------------------

    /**
     * @notice Lock `amount` of stakingToken and mint a position NFT to `msg.sender`.
     * @param amount The amount of tokens to lock.
     * @param lockPeriod The selected lock tier (1 week, 1 month, 3 months or 12 months).
     * @return tokenId The id of the minted NFT that represents the locked position.
     */
    function deposit(uint256 amount, LockPeriod lockPeriod) external nonReentrant returns (uint256 tokenId) {
        if (amount == 0) {
            revert InvalidAmount();
        }

        uint256 start = block.timestamp;

        uint256 unlockTime = _ceilToSlot(lockPeriod, block.timestamp);

        tokenId = ++nextTokenId;

        // Update effective NAV to realize any pending deltas that have unlocked
        _updateEffectiveNav(lockPeriod);

        // Use effective NAV that accounts for pending deltas to prevent MEV
        // This ensures new depositors don't immediately capture recent rewards
        uint256 entryNav = _effectiveNav(lockPeriod, block.timestamp);

        uint256 sharesAmount = Math.mulDiv(amount, PRECISION, entryNav);

        _positions[tokenId] = Position({
            sharesAmount: sharesAmount,
            startTimestamp: start,
            unlockTimestamp: unlockTime,
            lockPeriod: lockPeriod,
            entryNav: entryNav
        });

        uint256 previousTotalShares = totalSharesPerTier[lockPeriod];
        uint256 newTotalShares = previousTotalShares + sharesAmount;
        _rescalePendingNavOnShareChange(lockPeriod, previousTotalShares, newTotalShares);

        totalSharesPerTier[lockPeriod] = newTotalShares;
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

        // Update effective NAV before calculating position value
        _updateEffectiveNav(position.lockPeriod);

        uint256 unlockSlot = _floorToSlot(position.lockPeriod, position.unlockTimestamp);
        _realizeExpiredSharesUpTo(position.lockPeriod, unlockSlot);
        
        // Use effective NAV that accounts for locked profit
        uint256 effectiveNavNow = _effectiveNav(position.lockPeriod, currentTimestamp);
        _ensureNavCheckpoint(position.lockPeriod, unlockSlot, effectiveNavNow);

        _removePositionShares(position, unlockSlot);
        
        uint256 payout = Math.mulDiv(position.sharesAmount, effectiveNavNow, PRECISION);

        delete _positions[tokenId];
        _burn(tokenId);

        stakingToken.safeTransfer(owner_, payout);
        emit Withdrawn(owner_, tokenId, payout);
    }

    /**
     * @notice Withdraw the locked tokens before the unlock time, applying a penalty on accrued rewards.
     * @param tokenId The id of the NFT position to redeem early.
     */
    function earlyWithdraw(uint256 tokenId) external nonReentrant {
        Position memory position = _positions[tokenId];
        if (position.sharesAmount == 0) {
            revert PositionNotFound(tokenId);
        }

        address owner_ = ownerOf(tokenId);
        if (!_isAuthorized(owner_, msg.sender, tokenId)) {
            revert ERC721InsufficientApproval(msg.sender, tokenId);
        }

        uint256 currentTimestamp = block.timestamp;
        if (currentTimestamp >= position.unlockTimestamp) {
            revert EarlyWithdrawUnavailable(position.unlockTimestamp, currentTimestamp);
        }

        LockPeriod lockPeriod = position.lockPeriod;
        
        // Update effective NAV before calculating position value
        _updateEffectiveNav(lockPeriod);
        
        uint256 currentSlot = _floorToSlot(lockPeriod, currentTimestamp);
        _realizeExpiredSharesUpTo(lockPeriod, currentSlot);

        // Use effective NAV that accounts for locked profit
        uint256 navAtCurrent = _effectiveNav(lockPeriod, currentTimestamp);
        uint256 principal = Math.mulDiv(position.sharesAmount, position.entryNav, PRECISION);
        uint256 currentValue = Math.mulDiv(position.sharesAmount, navAtCurrent, PRECISION);
        uint256 profit;
        if (currentValue > principal) {
            profit = currentValue - principal;
        }

        uint256 penaltyAmount;
        if (profit != 0) {
            penaltyAmount = Math.mulDiv(profit, _penaltyPercent(lockPeriod), 100);
        }

        uint256 payout = currentValue - penaltyAmount;
        if (penaltyAmount != 0) {
            rewardDust += penaltyAmount;
        }
        uint256 unlockSlot = _floorToSlot(lockPeriod, position.unlockTimestamp);
        _removePositionShares(position, unlockSlot);

        delete _positions[tokenId];
        _burn(tokenId);

        stakingToken.safeTransfer(owner_, payout);

        emit EarlyWithdraw(owner_, tokenId, payout, penaltyAmount);
    }

    function distributeRewards(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert InvalidAmount();
        }

        address source = rewardSource;
        if (source == address(0)) {
            revert RewardSourceNotSet();
        }

        // First, update effective NAV for all tiers based on elapsed time
        // This realizes a portion of previously pending NAV deltas based on linear unlock schedule
        _updateEffectiveNav(LockPeriod.OneWeek);
        _updateEffectiveNav(LockPeriod.OneMonth);
        _updateEffectiveNav(LockPeriod.ThreeMonths);
        _updateEffectiveNav(LockPeriod.TwelveMonths);

        uint256 weekSlot = _floorToSlot(LockPeriod.OneWeek, block.timestamp);
        uint256 monthSlot = _floorToSlot(LockPeriod.OneMonth, block.timestamp);
        uint256 threeMonthSlot = _floorToSlot(LockPeriod.ThreeMonths, block.timestamp);
        uint256 twelveMonthSlot = _floorToSlot(LockPeriod.TwelveMonths, block.timestamp);

        uint256 weekShares = _activeSharesForSlot(LockPeriod.OneWeek, weekSlot);
        uint256 monthShares = _activeSharesForSlot(LockPeriod.OneMonth, monthSlot);
        uint256 threeMonthShares = _activeSharesForSlot(LockPeriod.ThreeMonths, threeMonthSlot);
        uint256 twelveMonthShares = _activeSharesForSlot(LockPeriod.TwelveMonths, twelveMonthSlot);

        uint256 weekBoostFactor = boostFactorPerTier[LockPeriod.OneWeek];
        uint256 monthBoostFactor = boostFactorPerTier[LockPeriod.OneMonth];
        uint256 threeMonthBoostFactor = boostFactorPerTier[LockPeriod.ThreeMonths];
        uint256 twelveMonthBoostFactor = boostFactorPerTier[LockPeriod.TwelveMonths];

        uint256 activeShares = weekShares * weekBoostFactor
            + monthShares * monthBoostFactor
            + threeMonthShares * threeMonthBoostFactor
            + twelveMonthShares * twelveMonthBoostFactor;
        if (activeShares == 0) {
            revert NoActiveShares();
        }

        stakingToken.safeTransferFrom(source, address(this), amount);

        uint256 totalReward = amount + rewardDust;
        uint256 distributed;

        uint256 weekNavDelta;
        if (weekShares != 0) {
            uint256 weekReward = Math.mulDiv(totalReward, weekShares * weekBoostFactor, activeShares);
            weekNavDelta = Math.mulDiv(weekReward, PRECISION, weekShares);
            // Add NAV delta to pending - it will unlock linearly over UNLOCK_DURATION_ONE_WEEK
            // Effective NAV will increase gradually as the delta unlocks
            tierPendingNav[LockPeriod.OneWeek].pendingNavDelta += weekNavDelta;
            _recordNavOnDistribution(LockPeriod.OneWeek, weekSlot);
            uint256 weekCredited = Math.mulDiv(weekNavDelta, weekShares, PRECISION);
            distributed += weekCredited;
        }

        uint256 monthNavDelta;
        if (monthShares != 0) {
            uint256 monthReward = Math.mulDiv(totalReward, monthShares * monthBoostFactor, activeShares);
            monthNavDelta = Math.mulDiv(monthReward, PRECISION, monthShares);
            // Add NAV delta to pending - it will unlock linearly over UNLOCK_DURATION_ONE_MONTH
            // Effective NAV will increase gradually as the delta unlocks
            tierPendingNav[LockPeriod.OneMonth].pendingNavDelta += monthNavDelta;
            _recordNavOnDistribution(LockPeriod.OneMonth, monthSlot);
            uint256 monthCredited = Math.mulDiv(monthNavDelta, monthShares, PRECISION);
            distributed += monthCredited;
        }

        uint256 threeMonthNavDelta;
        if (threeMonthShares != 0) {
            uint256 threeMonthReward = Math.mulDiv(totalReward, threeMonthShares * threeMonthBoostFactor, activeShares);
            threeMonthNavDelta = Math.mulDiv(threeMonthReward, PRECISION, threeMonthShares);
            // Add NAV delta to pending - it will unlock linearly over UNLOCK_DURATION_THREE_MONTHS
            // Effective NAV will increase gradually as the delta unlocks
            tierPendingNav[LockPeriod.ThreeMonths].pendingNavDelta += threeMonthNavDelta;
            _recordNavOnDistribution(LockPeriod.ThreeMonths, threeMonthSlot);
            uint256 threeMonthCredited = Math.mulDiv(threeMonthNavDelta, threeMonthShares, PRECISION);
            distributed += threeMonthCredited;
        }

        uint256 twelveMonthNavDelta;
        if (twelveMonthShares != 0) {
            uint256 twelveMonthReward =
                Math.mulDiv(totalReward, twelveMonthShares * twelveMonthBoostFactor, activeShares);
            twelveMonthNavDelta = Math.mulDiv(twelveMonthReward, PRECISION, twelveMonthShares);
            // Add NAV delta to pending - it will unlock linearly over UNLOCK_DURATION_TWELVE_MONTHS
            // Effective NAV will increase gradually as the delta unlocks
            tierPendingNav[LockPeriod.TwelveMonths].pendingNavDelta += twelveMonthNavDelta;
            _recordNavOnDistribution(LockPeriod.TwelveMonths, twelveMonthSlot);
            uint256 twelveMonthCredited = Math.mulDiv(twelveMonthNavDelta, twelveMonthShares, PRECISION);
            distributed += twelveMonthCredited;
        }

        rewardDust = totalReward - distributed;

        // Ensure a checkpoint exists for every tier at this slot,
        // even if a given tier received zero delta this round.
        _recordNavOnDistribution(LockPeriod.OneWeek, weekSlot);
        _recordNavOnDistribution(LockPeriod.OneMonth, monthSlot);
        _recordNavOnDistribution(LockPeriod.ThreeMonths, threeMonthSlot);
        _recordNavOnDistribution(LockPeriod.TwelveMonths, twelveMonthSlot);

        emit RewardsDistributed(
            msg.sender,
            amount,
            totalReward,
            weekSlot,
            weekNavDelta,
            monthNavDelta,
            threeMonthNavDelta,
            twelveMonthNavDelta,
            rewardDust
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

    /**
     * @notice Get the current effective NAV for a tier at the current timestamp
     * @dev This includes the base effective NAV plus any unlocked pending NAV deltas
     * @param lockPeriod The lock tier to query
     * @return The current effective NAV per share
     */
    function getCurrentEffectiveNav(LockPeriod lockPeriod) external view returns (uint256) {
        return _effectiveNav(lockPeriod, block.timestamp);
    }

    /// -----------------------------------------------------------------------
    /// Internal logic
    /// -----------------------------------------------------------------------
    
    /**
     * @dev Calculate the unlocked NAV delta for a tier at a given timestamp.
     *      The NAV delta unlocks linearly over the unlock duration.
     * @param lockPeriod The lock tier to calculate for
     * @param timestamp The timestamp to calculate at
     * @return The amount of NAV delta that has been unlocked
     */
    function _unlockedNavDelta(LockPeriod lockPeriod, uint256 timestamp) private view returns (uint256) {
        TierPendingNav storage tierPending = tierPendingNav[lockPeriod];
        
        if (tierPending.pendingNavDelta == 0) {
            return 0;
        }
        
        // If timestamp hasn't moved forward, nothing has unlocked yet
        if (timestamp <= tierPending.lastReport) {
            return 0;
        }
        
        uint256 elapsed = timestamp - tierPending.lastReport;
        
        if (elapsed >= tierPending.unlockDuration) {
            return tierPending.pendingNavDelta; // All NAV delta has been unlocked
        }
        
        // Calculate linearly increasing unlocked NAV delta
        return Math.mulDiv(
            tierPending.pendingNavDelta,
            elapsed,
            tierPending.unlockDuration
        );
    }
    
    /**
     * @dev Update the effective NAV for a tier based on elapsed time.
     *      This realizes pending NAV deltas proportionally and modifies storage.
     *      Should only be called during state-changing operations.
     * @param lockPeriod The lock tier to update
     */
    function _updateEffectiveNav(LockPeriod lockPeriod) private {
        TierPendingNav storage tierPending = tierPendingNav[lockPeriod];
        
        // Prevent issues if timestamp hasn't moved forward
        if (block.timestamp <= tierPending.lastReport) {
            return;
        }
        
        uint256 elapsed = block.timestamp - tierPending.lastReport;
        
        if (tierPending.pendingNavDelta == 0) {
            tierPending.lastReport = block.timestamp;
            return;
        }
        
        if (elapsed >= tierPending.unlockDuration) {
            // All pending NAV has been unlocked - add it to effective NAV
            effectiveNavPerTier[lockPeriod] += tierPending.pendingNavDelta;
            tierPending.pendingNavDelta = 0;
            tierPending.lastReport = block.timestamp;
        } else {
            // Realize pending NAV proportionally
            uint256 unlockedDelta = Math.mulDiv(
                tierPending.pendingNavDelta,
                elapsed,
                tierPending.unlockDuration
            );
            effectiveNavPerTier[lockPeriod] += unlockedDelta;
            tierPending.pendingNavDelta -= unlockedDelta;
            // Update lastReport to now so future calculations are relative to this point
            tierPending.lastReport = block.timestamp;
        }
    }
    
    /**
     * @dev Calculate the current effective NAV for a tier at a given timestamp.
     *      This is the NAV that should be used for deposits, withdrawals, and early withdrawals.
     *      Pure effective model: base effective NAV + unlocked pending NAV delta
     * @param lockPeriod The lock tier to calculate for
     * @param timestamp The timestamp to calculate at
     * @return The effective NAV per share
     */
    function _effectiveNav(LockPeriod lockPeriod, uint256 timestamp) private view returns (uint256) {
        uint256 baseNav = effectiveNavPerTier[lockPeriod];
        uint256 unlockedDelta = _unlockedNavDelta(lockPeriod, timestamp);
        return baseNav + unlockedDelta;
    }

    function _rescalePendingNavOnShareChange(
        LockPeriod lockPeriod,
        uint256 previousTotalShares,
        uint256 newTotalShares
    ) private {
        if (previousTotalShares == newTotalShares) {
            return;
        }

        TierPendingNav storage tierPending = tierPendingNav[lockPeriod];
        uint256 pendingNavDelta = tierPending.pendingNavDelta;
        if (pendingNavDelta == 0) {
            return;
        }

        if (previousTotalShares == 0) {
            // Pending NAV should already be zero when no shares exist, but guard just in case.
            if (newTotalShares == 0) {
                tierPending.pendingNavDelta = 0;
            }
            return;
        }

        uint256 lockedRewardBefore = Math.mulDiv(pendingNavDelta, previousTotalShares, PRECISION);
        if (lockedRewardBefore == 0) {
            tierPending.pendingNavDelta = 0;
            return;
        }

        if (newTotalShares == 0) {
            tierPending.pendingNavDelta = 0;
            rewardDust += lockedRewardBefore;
            return;
        }

        uint256 rescaledPending = Math.mulDiv(lockedRewardBefore, PRECISION, newTotalShares);
        uint256 lockedRewardAfter = Math.mulDiv(rescaledPending, newTotalShares, PRECISION);
        uint256 roundingLoss = lockedRewardBefore - lockedRewardAfter;
        if (roundingLoss != 0) {
            rewardDust += roundingLoss;
        }

        tierPending.pendingNavDelta = rescaledPending;
    }

    function _slotSize(LockPeriod lockPeriod) private pure returns (uint256) {
        if (lockPeriod == LockPeriod.OneWeek) {
            return ONE_WEEK;
        }
        if (lockPeriod == LockPeriod.OneMonth) {
            return FOUR_WEEKS;
        }
        if (lockPeriod == LockPeriod.ThreeMonths) {
            return TWELVE_WEEKS;
        }
        if (lockPeriod == LockPeriod.TwelveMonths) {
            return FORTY_EIGHT_WEEKS;
        }
        revert InvalidLockPeriod();
    }

    function _penaltyPercent(LockPeriod lockPeriod) private pure returns (uint256) {
        if (lockPeriod == LockPeriod.OneWeek) {
            return 30;
        }
        if (lockPeriod == LockPeriod.OneMonth) {
            return 40;
        }
        if (lockPeriod == LockPeriod.ThreeMonths) {
            return 60;
        }
        if (lockPeriod == LockPeriod.TwelveMonths) {
            return 75;
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
        if (effectiveNavPerTierAtSlot[lockPeriod][slot] != 0) {
            return;
        }
        effectiveNavPerTierAtSlot[lockPeriod][slot] = navValue;
        uint256[] storage slots = _navSlots[lockPeriod];
        uint256 len = slots.length;
        if (len == 0 || slots[len - 1] < slot) {
            slots.push(slot);
        }
    }

    function _setNavCheckpoint(LockPeriod lockPeriod, uint256 slot, uint256 navValue) private {
        if (effectiveNavPerTierAtSlot[lockPeriod][slot] == 0) {
            effectiveNavPerTierAtSlot[lockPeriod][slot] = navValue;
            uint256[] storage slots = _navSlots[lockPeriod];
            uint256 len = slots.length;
            if (len == 0 || slots[len - 1] < slot) {
                slots.push(slot);
            }
            return;
        }
        effectiveNavPerTierAtSlot[lockPeriod][slot] = navValue;
    }

    function _recordNavOnDistribution(LockPeriod lockPeriod, uint256 slot) private {
        // Record the current effective NAV (including partially unlocked pending deltas)
        uint256 currentEffectiveNav = _effectiveNav(lockPeriod, block.timestamp);
        _setNavCheckpoint(lockPeriod, slot, currentEffectiveNav);
        uint256 nextSlot = slot + _slotSize(lockPeriod);
        _setNavCheckpoint(lockPeriod, nextSlot, currentEffectiveNav);
    }

    // Note: _navAtOrBefore and _fallbackNavAtOrBefore have been removed as they are no longer needed
    // with the new locked profit model. The effective NAV is now calculated using _effectiveNav()
    // which accounts for locked profit that unlocks linearly over time.

    function _realizeExpiredSharesUpTo(LockPeriod lockPeriod, uint256 slot) private {
        uint256 targetSlot = _floorToSlot(lockPeriod, slot);
        uint256 lastSlot = _lastExpiredSlotUpdated[lockPeriod];
        uint256 cumulative = cumulativeExpiredShares[lockPeriod];

        if (targetSlot <= lastSlot) {
            cumulativeExpiredSharesAtSlot[lockPeriod][targetSlot] = cumulative;
            uint256 currentEffectiveNav = _effectiveNav(lockPeriod, block.timestamp);
            _ensureNavCheckpoint(lockPeriod, targetSlot, currentEffectiveNav);
            return;
        }

        uint256 size = _slotSize(lockPeriod);
        uint256 current = lastSlot;
        while (current < targetSlot) {
            current += size;
            cumulative += expiredSharesAtSlot[lockPeriod][current];
            cumulativeExpiredSharesAtSlot[lockPeriod][current] = cumulative;
            uint256 currentEffectiveNav = _effectiveNav(lockPeriod, block.timestamp);
            _ensureNavCheckpoint(lockPeriod, current, currentEffectiveNav);
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

    function _removePositionShares(Position memory position, uint256 unlockSlot) private {
        LockPeriod lockPeriod = position.lockPeriod;
        uint256 sharesAmount = position.sharesAmount;

        uint256 previousTotalShares = totalSharesPerTier[lockPeriod];
        uint256 newTotalShares = previousTotalShares - sharesAmount;

        _rescalePendingNavOnShareChange(lockPeriod, previousTotalShares, newTotalShares);

        totalSharesPerTier[lockPeriod] = newTotalShares;

        uint256 expiredForSlot = expiredSharesAtSlot[lockPeriod][unlockSlot];
        if (expiredForSlot == 0) {
            return;
        }

        uint256 amountToRemove = expiredForSlot < sharesAmount ? expiredForSlot : sharesAmount;
        if (_lastExpiredSlotUpdated[lockPeriod] >= unlockSlot) {
            cumulativeExpiredShares[lockPeriod] -= amountToRemove;
            cumulativeExpiredSharesAtSlot[lockPeriod][unlockSlot] = cumulativeExpiredShares[lockPeriod];
        }

        expiredSharesAtSlot[lockPeriod][unlockSlot] = expiredForSlot - amountToRemove;
        if (_lastExpiredSlotUpdated[lockPeriod] > unlockSlot) {
            _lastExpiredSlotUpdated[lockPeriod] = unlockSlot;
        }
    }
    /***** Governance ******/
    function getUserLockPowah(address user) external view returns (uint256 totalPower) {
        uint256 balance = balanceOf(user);
        uint256[] memory nfts = new uint256[](balance);

        for (uint256 i = 0; i < balance; i++) {
            nfts[i] = tokenOfOwnerByIndex(user, i);
            Position memory position = _positions[nfts[i]];
            if (position.unlockTimestamp < block.timestamp) {
                continue;
            }
            // Use effective NAV that accounts for locked profit
            uint256 currentNav = _effectiveNav(position.lockPeriod, block.timestamp);
            totalPower += Math.mulDiv(position.sharesAmount, currentNav, PRECISION);
        }
    }
}
