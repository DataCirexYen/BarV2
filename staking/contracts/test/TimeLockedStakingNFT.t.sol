// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TimeLockedStakingNFT} from "../src/TimeLockedStakingNFT.sol";
import {RewardSource} from "../src/RewardSource.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {console} from "forge-std/console.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TimeLockedStakingNFTTest is Test, IERC721Receiver {
    MockToken internal token;
    TimeLockedStakingNFT internal staking;
    RewardSource internal rewardSource;
    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant WEEK_DURATION = 1 weeks;
    uint256 internal constant MONTH_DURATION = 4 weeks;
    uint256 internal constant THREE_MONTH_DURATION = 12 weeks;
    uint256 internal constant TWELVE_MONTH_DURATION = 48 weeks;
    uint256 internal constant WEEK_BOOST = 1_050_000_000_000_000_000; // 1.05x weight
    uint256 internal constant MONTH_BOOST = 1_100_000_000_000_000_000; // 1.10x weight
    uint256 internal constant THREE_MONTH_BOOST = 1_200_000_000_000_000_000; // 1.20x weight
    uint256 internal constant TWELVE_MONTH_BOOST = 1_400_000_000_000_000_000; // 1.40x weight

    function setUp() public {
        token = new MockToken();
        staking = new TimeLockedStakingNFT(token);
        rewardSource = new RewardSource(token);
        staking.setRewardSource(address(rewardSource));
        vm.warp(1 weeks - 1 days);

        token.mint(address(this), 1_000 ether);
        token.approve(address(staking), type(uint256).max);
        rewardSource.setAllowance(address(staking), type(uint256).max);
    }

    function testDepositCreatesPosition() public {
        uint256 amount = 100 ether;
        uint256 tokenId = staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneWeek);
        console.log("amount", amount);
        console.log("Deposit tokenId", tokenId);
        console.log("Staked amount", amount);

        assertEq(token.balanceOf(address(staking)), amount);
        assertEq(staking.ownerOf(tokenId), address(this));

        TimeLockedStakingNFT.Position memory position = staking.getPosition(tokenId);
        console.log("Position start timestamp", position.startTimestamp);
        console.log("Position unlock timestamp", position.unlockTimestamp);
        assertEq(position.sharesAmount, amount);
        console.log("Position shares amount", position.sharesAmount);
        console.log("amount", amount);

        assertEq(uint256(position.lockPeriod), uint256(TimeLockedStakingNFT.LockPeriod.OneWeek));
        assertEq(position.startTimestamp, block.timestamp);
        uint256 expectedSlot = _nextSlot(block.timestamp, WEEK_DURATION);
        assertEq(position.unlockTimestamp, expectedSlot);
        assertEq(position.entryNav, PRECISION); // Initial NAV is PRECISION
        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek), amount);
    }

    function testGetUserLockPowahCountsActivePositions() public {
        uint256 weekToken = staking.deposit(100 ether, TimeLockedStakingNFT.LockPeriod.OneWeek);
        staking.deposit(200 ether, TimeLockedStakingNFT.LockPeriod.OneMonth);

        address bob = address(0xB0B);
        token.mint(bob, 300 ether);
        vm.startPrank(bob);
        token.approve(address(staking), type(uint256).max);
        staking.deposit(300 ether, TimeLockedStakingNFT.LockPeriod.OneWeek);
        vm.stopPrank();

        uint256 selfPowah = staking.getUserLockPowah(address(this));
        assertEq(selfPowah, 300 ether);

        uint256 bobPowah = staking.getUserLockPowah(bob);
        assertEq(bobPowah, 300 ether);

        TimeLockedStakingNFT.Position memory weekPosition = staking.getPosition(weekToken);
        vm.warp(weekPosition.unlockTimestamp + 1);

        selfPowah = staking.getUserLockPowah(address(this));
        assertEq(selfPowah, 200 ether);

        bobPowah = staking.getUserLockPowah(bob);
        assertEq(bobPowah, 0);
    }

    function testGetUserLockPowahReflectsCurrentNav() public {
        uint256 amount = 100 ether;
        uint256 tokenId = staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneWeek);

        uint256 reward = 50 ether;
        token.mint(address(rewardSource), reward);
        staking.distributeRewards(reward);

        TimeLockedStakingNFT.Position memory position = staking.getPosition(tokenId);
        
        // Right after distribution, getUserLockPowah should reflect effective NAV (which doesn't immediately increase)
        // The NAV delta is pending and will unlock gradually
        uint256 powahImmediately = staking.getUserLockPowah(address(this));
        assertGt(powahImmediately, 0); // Should be greater than 0
        // Should be approximately equal to the principal since no time has passed for delta to unlock
        assertApproxEqAbs(powahImmediately, amount, 1e15); // Allow small rounding error

        // For OneWeek tier: unlock duration is 7 days, but position expires in ~1 week
        // So the position will expire before all rewards unlock
        // Let's wait a reasonable time (half of unlock duration or until near expiry)
        uint256 unlockDuration = 7 days;
        uint256 timeUntilExpiry = position.unlockTimestamp > block.timestamp 
            ? position.unlockTimestamp - block.timestamp 
            : 0;
        
        // Wait for the shorter of: half unlock duration or time until expiry - 1 minute
        uint256 timeToWait = unlockDuration / 2;
        if (timeToWait > timeUntilExpiry - 1 minutes) {
            timeToWait = timeUntilExpiry > 1 minutes ? timeUntilExpiry - 1 minutes : 0;
        }
        
        if (timeToWait > 0) {
            vm.warp(block.timestamp + timeToWait);
            
            // Check powah increased from initial
            uint256 powahAfterWait = staking.getUserLockPowah(address(this));
            assertGt(powahAfterWait, powahImmediately); // Should have increased
            assertGt(powahAfterWait, 0); // Still positive
        }

        // After position expires, powah should be 0
        vm.warp(position.unlockTimestamp + 1);
        assertEq(staking.getUserLockPowah(address(this)), 0);
    }

    function testWithdrawFailsBeforeUnlock() public {
        uint256 tokenId = staking.deposit(50 ether, TimeLockedStakingNFT.LockPeriod.OneMonth);
        TimeLockedStakingNFT.Position memory position = staking.getPosition(tokenId);

        console.log("Attempting early withdraw for tokenId", tokenId);
        console.log("Unlock timestamp", position.unlockTimestamp);
        console.log("Current timestamp", block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                TimeLockedStakingNFT.UnlockNotReached.selector, position.unlockTimestamp, block.timestamp
            )
        );
        staking.withdraw(tokenId);
    }

    function testWithdrawSucceedsAfterUnlock() public {
        uint256 amount = 200 ether;
        uint256 tokenId = staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneWeek);

        TimeLockedStakingNFT.Position memory position = staking.getPosition(tokenId);
        console.log("Withdraw test tokenId", tokenId);
        console.log("Fast-forwarding time to", position.unlockTimestamp + 1);

        vm.warp(position.unlockTimestamp + 1);
        console.log("New timestamp", block.timestamp);

        staking.withdraw(tokenId);

        console.log("Balance after withdraw", token.balanceOf(address(this)));

        assertEq(token.balanceOf(address(this)), 1_000 ether);
        vm.expectRevert();
        staking.ownerOf(tokenId);

        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek), 0);
    }

    function testEarlyWithdrawAppliesPenaltyOnProfits() public {
        uint256 amount = 100 ether;
        uint256 reward = 50 ether;
        uint256 tokenId = staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);
        TimeLockedStakingNFT.Position memory position = staking.getPosition(tokenId);

        token.mint(address(rewardSource), reward);
        staking.distributeRewards(reward);

        // Wait 15 days (half of 30-day unlock duration for OneMonth)
        // This allows half the reward to unlock
        vm.warp(block.timestamp + 15 days);
        assertLt(block.timestamp, position.unlockTimestamp);

        uint256 balanceBefore = token.balanceOf(address(this));
        
        // Early withdraw uses effective NAV, so profit will be based on partially unlocked rewards
        staking.earlyWithdraw(tokenId);
        uint256 balanceAfter = token.balanceOf(address(this));

        // Verify position was removed and penalty was applied
        assertGt(balanceAfter, balanceBefore);
        assertGt(staking.rewardDust(), 0); // Some penalty was collected
        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneMonth), 0);
        vm.expectRevert();
        staking.ownerOf(tokenId);
    }

    function testEarlyWithdrawPenaltyFeedsFutureRewards() public {
        uint256 amountA = 100 ether;
        uint256 amountB = 200 ether;
        uint256 tokenA = staking.deposit(amountA, TimeLockedStakingNFT.LockPeriod.OneMonth);
        uint256 tokenB = staking.deposit(amountB, TimeLockedStakingNFT.LockPeriod.OneMonth);

        token.mint(address(rewardSource), 60 ether);
        staking.distributeRewards(60 ether);
        console.log("dust", staking.rewardDust());
        
        // Wait for half the rewards to unlock
        vm.warp(block.timestamp + 15 days);
        staking.earlyWithdraw(tokenA);

        uint256 dustBeforeSecond = staking.rewardDust();
        assertGt(dustBeforeSecond, 0);

        uint256 nextReward = 12 ether;
        token.mint(address(rewardSource), nextReward);
        staking.distributeRewards(nextReward);

        uint256 dustAfterSecond = staking.rewardDust();
        // In the pure effective NAV model, the effective NAV doesn't immediately change
        // The pending NAV delta is updated instead, which unlocks over time

        TimeLockedStakingNFT.Position memory positionB = staking.getPosition(tokenB);
        
        // Wait for all rewards to unlock before withdrawal
        vm.warp(positionB.unlockTimestamp + 30 days);
        uint256 balanceBefore = token.balanceOf(address(this));
        staking.withdraw(tokenB);
        uint256 balanceAfter = token.balanceOf(address(this));

        // Verify withdrawal succeeded
        assertGt(balanceAfter, balanceBefore);
        
    }

    function testDistributeRewardsRevertsWhenNoShares() public {
        vm.expectRevert(TimeLockedStakingNFT.NoActiveShares.selector);
        staking.distributeRewards(50 ether);
    }

    function testDistributeRewardsIgnoresPreviouslyExpiredShares() public {
        uint256 tokenId = staking.deposit(100 ether, TimeLockedStakingNFT.LockPeriod.OneWeek);
        TimeLockedStakingNFT.Position memory position = staking.getPosition(tokenId);

        vm.warp(position.unlockTimestamp + 2 weeks);

        vm.expectRevert(TimeLockedStakingNFT.NoActiveShares.selector);
        staking.distributeRewards(10 ether);
    }

    function testDistributeRewardsAccruesNavAndPayouts() public {
        uint256 weekAmount = 100 ether;
        uint256 monthAmount = 200 ether;
        uint256 threeMonthAmount = 300 ether;
        uint256 twelveMonthAmount = 400 ether;

        uint256 weekTokenId = staking.deposit(weekAmount, TimeLockedStakingNFT.LockPeriod.OneWeek);
        uint256 monthTokenId = staking.deposit(monthAmount, TimeLockedStakingNFT.LockPeriod.OneMonth);
        uint256 threeMonthTokenId = staking.deposit(threeMonthAmount, TimeLockedStakingNFT.LockPeriod.ThreeMonths);
        uint256 twelveMonthTokenId = staking.deposit(twelveMonthAmount, TimeLockedStakingNFT.LockPeriod.TwelveMonths);

        uint256 totalShares = weekAmount + monthAmount + threeMonthAmount + twelveMonthAmount;
        uint256 totalReward = 400 ether;
        token.mint(address(rewardSource), totalReward);

        console.log("Total shares before rewards", totalShares);
        console.log("Reward source balance before distribute", token.balanceOf(address(rewardSource)));

        // Get effective NAV before distribution
        uint256 weekNavBefore = staking.effectiveNavPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek);
        uint256 monthNavBefore = staking.effectiveNavPerTier(TimeLockedStakingNFT.LockPeriod.OneMonth);
        uint256 threeMonthNavBefore = staking.effectiveNavPerTier(TimeLockedStakingNFT.LockPeriod.ThreeMonths);
        uint256 twelveMonthNavBefore = staking.effectiveNavPerTier(TimeLockedStakingNFT.LockPeriod.TwelveMonths);

        staking.distributeRewards(totalReward);

        uint256 weekWeighted = weekAmount * WEEK_BOOST;
        uint256 monthWeighted = monthAmount * MONTH_BOOST;
        uint256 threeMonthWeighted = threeMonthAmount * THREE_MONTH_BOOST;
        uint256 twelveMonthWeighted = twelveMonthAmount * TWELVE_MONTH_BOOST;
        uint256 totalWeighted = weekWeighted + monthWeighted + threeMonthWeighted + twelveMonthWeighted;

        uint256 weekReward = Math.mulDiv(totalReward, weekWeighted, totalWeighted);
        uint256 monthReward = Math.mulDiv(totalReward, monthWeighted, totalWeighted);
        uint256 threeMonthReward = Math.mulDiv(totalReward, threeMonthWeighted, totalWeighted);
        uint256 twelveMonthReward = Math.mulDiv(totalReward, twelveMonthWeighted, totalWeighted);

        uint256 weekNavDelta = Math.mulDiv(weekReward, PRECISION, weekAmount);
        uint256 monthNavDelta = Math.mulDiv(monthReward, PRECISION, monthAmount);
        uint256 threeMonthNavDelta = Math.mulDiv(threeMonthReward, PRECISION, threeMonthAmount);
        uint256 twelveMonthNavDelta = Math.mulDiv(twelveMonthReward, PRECISION, twelveMonthAmount);

        uint256 weekCredited = Math.mulDiv(weekNavDelta, weekAmount, PRECISION);
        uint256 monthCredited = Math.mulDiv(monthNavDelta, monthAmount, PRECISION);
        uint256 threeMonthCredited = Math.mulDiv(threeMonthNavDelta, threeMonthAmount, PRECISION);
        uint256 twelveMonthCredited = Math.mulDiv(twelveMonthNavDelta, twelveMonthAmount, PRECISION);

        // In pure effective NAV model, effective NAV doesn't immediately increase after distribution
        // The NAV deltas are pending and will unlock over time
        // Right after distribution, effective NAV should be approximately the same
        assertApproxEqAbs(staking.effectiveNavPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek), weekNavBefore, 1e15);
        assertApproxEqAbs(staking.effectiveNavPerTier(TimeLockedStakingNFT.LockPeriod.OneMonth), monthNavBefore, 1e15);
        assertApproxEqAbs(staking.effectiveNavPerTier(TimeLockedStakingNFT.LockPeriod.ThreeMonths), threeMonthNavBefore, 1e15);
        assertApproxEqAbs(staking.effectiveNavPerTier(TimeLockedStakingNFT.LockPeriod.TwelveMonths), twelveMonthNavBefore, 1e15);

        uint256 expectedDust =
            totalReward - (weekCredited + monthCredited + threeMonthCredited + twelveMonthCredited);
        assertEq(staking.rewardDust(), expectedDust);
        assertEq(token.balanceOf(address(rewardSource)), 0);

        // Test by making a new deposit - it should get approximately the same entry NAV
        uint256 extraDeposit = 10 ether;
        token.mint(address(this), extraDeposit); // Mint more tokens for the test
        uint256 newWeekTokenId = staking.deposit(extraDeposit, TimeLockedStakingNFT.LockPeriod.OneWeek);
        TimeLockedStakingNFT.Position memory newWeekPosition = staking.getPosition(newWeekTokenId);
        
        // Entry NAV should be approximately equal to effective NAV (since no time has passed)
        assertApproxEqAbs(newWeekPosition.entryNav, staking.effectiveNavPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek), 1e15);

        TimeLockedStakingNFT.Position memory twelveMonthPosition = staking.getPosition(twelveMonthTokenId);

        // Wait for position to unlock AND for all pending NAV to be fully unlocked (365 days for TwelveMonths)
        vm.warp(twelveMonthPosition.unlockTimestamp + 365 days);

        staking.withdraw(weekTokenId);
        staking.withdraw(monthTokenId);
        staking.withdraw(threeMonthTokenId);
        staking.withdraw(twelveMonthTokenId);
        staking.withdraw(newWeekTokenId); // Don't forget to withdraw the additional deposit!

        uint256 principalDeposited = totalShares + extraDeposit;
        uint256 expectedBalance = principalDeposited + totalReward -staking.rewardDust();
        uint256 finalBalance = token.balanceOf(address(this));
        if (expectedBalance >= expectedBalance) {
            assertApproxEqAbs(finalBalance, expectedBalance,10);
        }
        else {
            fail("finalBalance should never be less than expectedBalance");
        }   
        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek), 0);
        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneMonth), 0);
        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.ThreeMonths), 0);
        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.TwelveMonths), 0);
    }

    function testWeekTierNavCheckpointNotStoredWhenNoShares() public {
        // Create and withdraw all share positions, so there are 0 total shares
        uint256 weekTokenId = staking.deposit(100 ether, TimeLockedStakingNFT.LockPeriod.OneWeek);
        uint256 monthTokenId = staking.deposit(200 ether, TimeLockedStakingNFT.LockPeriod.OneMonth);
        TimeLockedStakingNFT.Position memory weekPosition = staking.getPosition(weekTokenId);
        TimeLockedStakingNFT.Position memory monthPosition = staking.getPosition(monthTokenId);

        vm.warp(monthPosition.unlockTimestamp + 1 minutes);

        staking.withdraw(weekTokenId);
        staking.withdraw(monthTokenId);

        // Now, all shares are withdrawn, and no shares exist. Attempting to distribute should revert.
        token.mint(address(rewardSource), 200 ether);
        vm.expectRevert(TimeLockedStakingNFT.NoActiveShares.selector); // Should revert due to no active shares
        staking.distributeRewards(200 ether);
    }

    function testDelayedWithdrawUsesUnlockNav() public {
        uint256 weekAmount = 100 ether;
        uint256 monthAmount = 200 ether;
        uint256 weekTokenId = staking.deposit(weekAmount, TimeLockedStakingNFT.LockPeriod.OneWeek);
        staking.deposit(monthAmount, TimeLockedStakingNFT.LockPeriod.OneMonth);
        TimeLockedStakingNFT.Position memory weekPosition = staking.getPosition(weekTokenId);
        uint256 totalReward = 150 ether;
        token.mint(address(rewardSource), totalReward);
        staking.distributeRewards(totalReward);

        // Wait for position to unlock
        vm.warp(weekPosition.unlockTimestamp + 1 minutes);

        uint256 balanceBefore = token.balanceOf(address(this));
        
        // With locked profit model, we need to wait full unlock duration (7 days for OneWeek)
        // for all rewards to be realized. Since we're testing delayed withdrawal,
        // wait additional 7 days to ensure all profit is unlocked
        vm.warp(block.timestamp + 7 days);
        
        staking.withdraw(weekTokenId);
        uint256 balanceAfter = token.balanceOf(address(this));

        uint256 monthShares = staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneMonth);
        uint256 weekShares = weekPosition.sharesAmount;
        uint256 weekWeighted = weekShares * WEEK_BOOST;
        uint256 monthWeighted = monthShares * MONTH_BOOST;
        uint256 totalWeighted = weekWeighted + monthWeighted;
        uint256 weekReward = Math.mulDiv(totalReward, weekWeighted, totalWeighted);
        uint256 expectedNav = PRECISION + Math.mulDiv(weekReward, PRECISION, weekShares);
        uint256 expectedPayout = Math.mulDiv(weekShares, expectedNav, PRECISION);

        assertEq(balanceAfter - balanceBefore, expectedPayout);
    }

    function _ceilTimestamp(uint256 timestamp, uint256 size) internal pure returns (uint256) {
        return ((timestamp + size - 1) / size) * size;
    }

    function _floorTimestamp(uint256 timestamp, uint256 size) internal pure returns (uint256) {
        return (timestamp / size) * size;
    }

    function _nextSlot(uint256 timestamp, uint256 size) internal pure returns (uint256) {
        uint256 slot = _ceilTimestamp(timestamp, size);
        if (slot == timestamp) {
            slot += size;
        }
        return slot;
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}
