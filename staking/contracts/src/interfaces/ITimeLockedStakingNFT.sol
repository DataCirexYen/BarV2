// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface ITimeLockedStakingNFT {
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
    /// Storage getters
    /// -----------------------------------------------------------------------

    function stakingToken() external view returns (IERC20);

    function nextTokenId() external view returns (uint256);

    function totalSharesPerTier(LockPeriod lockPeriod) external view returns (uint256);

    function navPerTier(LockPeriod lockPeriod) external view returns (uint256);

    function navPerTierAtSlot(LockPeriod lockPeriod, uint256 slot) external view returns (uint256);

    function expiredSharesAtSlot(LockPeriod lockPeriod, uint256 slot) external view returns (uint256);

    function cumulativeExpiredShares(LockPeriod lockPeriod) external view returns (uint256);

    function cumulativeExpiredSharesAtSlot(LockPeriod lockPeriod, uint256 slot) external view returns (uint256);

    function boostFactorPerTier(LockPeriod lockPeriod) external view returns (uint256);

    function rewardSource() external view returns (address);

    function rewardDust() external view returns (uint256);

    /// -----------------------------------------------------------------------
    /// External functions
    /// -----------------------------------------------------------------------

    function deposit(uint256 amount, LockPeriod lockPeriod) external returns (uint256 tokenId);

    function withdraw(uint256 tokenId) external;

    function earlyWithdraw(uint256 tokenId) external;

    function distributeRewards(uint256 amount) external;

    function setRewardSource(address newRewardSource) external;

    function setBoostFactorPerTier(LockPeriod lockPeriod, uint256 boostFactor) external;

    function getPosition(uint256 tokenId) external view returns (Position memory);

    function timeUntilUnlock(uint256 tokenId) external view returns (uint256);

    function isUnlockable(uint256 tokenId) external view returns (bool);

    function getUserLockPowah(address user) external view returns (uint256 totalPower);
}
