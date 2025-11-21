// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test,console} from "forge-std/Test.sol";
import {TimeLockedStakingNFT} from "../src/TimeLockedStakingNFT.sol";
import {RewardSource} from "../src/RewardSource.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TimeLockedStakingNFTLockedProfitTest is Test, IERC721Receiver {
    MockToken internal token;
    TimeLockedStakingNFT internal staking;
    RewardSource internal rewardSource;
    uint256 internal constant PRECISION = 1e18;
    
    // Unlock durations from the contract
    uint256 internal constant UNLOCK_DURATION_ONE_WEEK = 7 days;
    uint256 internal constant UNLOCK_DURATION_ONE_MONTH = 30 days;
    uint256 internal constant UNLOCK_DURATION_THREE_MONTHS = 90 days;
    uint256 internal constant UNLOCK_DURATION_TWELVE_MONTHS = 365 days;

    function setUp() public {
        token = new MockToken();
        staking = new TimeLockedStakingNFT(token);
        rewardSource = new RewardSource(token);
        staking.setRewardSource(address(rewardSource));
        
        token.mint(address(this), 10_000 ether);
        token.approve(address(staking), type(uint256).max);
        rewardSource.setAllowance(address(staking), type(uint256).max);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _unlockedNavDeltaAt(uint256 pendingNavDelta, uint256 lastReport, uint256 unlockDuration, uint256 timestamp)
        internal
        pure
        returns (uint256)
    {
        if (pendingNavDelta == 0) {
            return 0;
        }
        if (timestamp <= lastReport) {
            return 0;
        }
        uint256 elapsed = timestamp - lastReport;
        if (elapsed >= unlockDuration) {
            return pendingNavDelta;
        }
        return Math.mulDiv(pendingNavDelta, elapsed, unlockDuration);
    }

    function _expectedEffectiveNavFromState(TimeLockedStakingNFT.LockPeriod lockPeriod, uint256 timestamp)
        internal
        view
        returns (uint256)
    {
        uint256 baseNav = staking.effectiveNavPerTier(lockPeriod);
        (uint256 pendingNavDelta, uint256 lastReport, uint256 unlockDuration) = staking.tierPendingNav(lockPeriod);
        uint256 unlockedDelta = _unlockedNavDeltaAt(pendingNavDelta, lastReport, unlockDuration, timestamp);
        return baseNav + unlockedDelta;
    }

    function _expectedPowahFromState(
        TimeLockedStakingNFT.LockPeriod lockPeriod,
        uint256 shares,
        uint256 timestamp
    ) internal view returns (uint256) {
        uint256 currentNav = _expectedEffectiveNavFromState(lockPeriod, timestamp);
        return Math.mulDiv(shares, currentNav, PRECISION);
    }

    function testLinearUnlockingOfRewards() public {
        // Deposit into one week tier
        uint256 depositAmount = 1000 ether;
        uint256 tokenId = staking.deposit(depositAmount, TimeLockedStakingNFT.LockPeriod.OneWeek);
        
        // Distribute rewards
        uint256 rewardAmount = 100 ether;
        token.mint(address(rewardSource), rewardAmount);
        
        uint256 navBefore = staking.effectiveNavPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek);
        staking.distributeRewards(rewardAmount);
        
        // In pure effective NAV model, effective NAV doesn't immediately increase
        // The NAV delta is pending and will unlock over time
        uint256 navAfter = staking.effectiveNavPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek);
        assertApproxEqAbs(navAfter, navBefore, 1e15); // Should be approximately same
        
        // But a new depositor right after distribution should get approximately the same NAV
        uint256 tokenId2 = staking.deposit(depositAmount, TimeLockedStakingNFT.LockPeriod.OneWeek);
        TimeLockedStakingNFT.Position memory position2 = staking.getPosition(tokenId2);
        
        // The entry NAV should be approximately the same as before since no time passed
        assertApproxEqAbs(position2.entryNav, navBefore, 1e15);
        
        // After 3.5 days (half of unlock duration), about half the reward should be unlocked
        vm.warp(block.timestamp + 3.5 days);
        uint256 tokenId3 = staking.deposit(depositAmount, TimeLockedStakingNFT.LockPeriod.OneWeek);
        TimeLockedStakingNFT.Position memory position3 = staking.getPosition(tokenId3);
        
        // Entry NAV should be higher than the initial position as rewards unlock
        assertGt(position3.entryNav, position2.entryNav);
        
        // After full unlock duration, all rewards should be unlocked
        vm.warp(block.timestamp + 3.5 days + 1);
        uint256 tokenId4 = staking.deposit(depositAmount, TimeLockedStakingNFT.LockPeriod.OneWeek);
        TimeLockedStakingNFT.Position memory position4 = staking.getPosition(tokenId4);
        
        // Now entry NAV should be even higher (full rewards unlocked)
        assertGt(position4.entryNav, position3.entryNav);
    }

    function testMEVMitigationSandwichAttack() public {
        // Existing depositor
        uint256 aliceDeposit = 1000 ether;
        uint256 aliceTokenId = staking.deposit(aliceDeposit, TimeLockedStakingNFT.LockPeriod.OneWeek);
        
        // MEV bot tries to sandwich the distributeRewards call
        address mevBot = address(0xBADB0B);
        token.mint(mevBot, 10000 ether);
        
        vm.startPrank(mevBot);
        token.approve(address(staking), type(uint256).max);
        
        // Bot deposits right before rewards distribution
        uint256 botDeposit = 10000 ether;
        uint256 botTokenId = staking.deposit(botDeposit, TimeLockedStakingNFT.LockPeriod.OneWeek);
        vm.stopPrank();
        
        // Large reward distribution happens
        uint256 rewardAmount = 1000 ether;
        token.mint(address(rewardSource), rewardAmount);
        staking.distributeRewards(rewardAmount);
        
        // Bot tries to withdraw immediately (early withdraw since still locked)
        vm.startPrank(mevBot);
        
        // Get bot position details
        TimeLockedStakingNFT.Position memory botPosition = staking.getPosition(botTokenId);
        
        // Calculate expected payout with penalty
        uint256 balanceBefore = token.balanceOf(mevBot);
        staking.earlyWithdraw(botTokenId);
        uint256 balanceAfter = token.balanceOf(mevBot);
        
        uint256 payout = balanceAfter - balanceBefore;
        vm.stopPrank();
        
        // Bot should not profit significantly because:
        // 1. The effective NAV hasn't increased much due to locked profit
        // 2. Early withdrawal penalty applies
        assertLt(payout, botDeposit + 10 ether); // Bot gets back less than deposit + small amount
        
        // Meanwhile, legitimate user who waits gets full rewards
        TimeLockedStakingNFT.Position memory alicePosition = staking.getPosition(aliceTokenId);
        vm.warp(alicePosition.unlockTimestamp + 1);
        
        balanceBefore = token.balanceOf(address(this));
        staking.withdraw(aliceTokenId);
        balanceAfter = token.balanceOf(address(this));
        
        uint256 alicePayout = balanceAfter - balanceBefore;
        
        // Alice should get significantly more than her initial deposit
        assertGt(alicePayout, aliceDeposit + 40 ether); // Alice profits from rewards
    }

    function testDifferentUnlockDurationsPerTier() public {
        // Deposit same amount in each tier
        uint256 amount = 1000 ether;
        staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneWeek);
        staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);
        staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.ThreeMonths);
        staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.TwelveMonths);
        
        // Distribute rewards
        uint256 rewardAmount = 1000 ether;
        token.mint(address(rewardSource), rewardAmount);
        staking.distributeRewards(rewardAmount);
        
        // After 7 days, OneWeek tier should be fully unlocked
        vm.warp(block.timestamp + 7 days);
        uint256 weekNavCurrent = staking.getCurrentEffectiveNav(TimeLockedStakingNFT.LockPeriod.OneWeek);
        uint256 weekTokenId = staking.deposit(1 ether, TimeLockedStakingNFT.LockPeriod.OneWeek);
        TimeLockedStakingNFT.Position memory weekPos = staking.getPosition(weekTokenId);
        assertEq(weekPos.entryNav, weekNavCurrent); // Fully unlocked
        
        // But OneMonth tier should still be partially unlocked (not full yet)
        uint256 monthNavPartial = staking.getCurrentEffectiveNav(TimeLockedStakingNFT.LockPeriod.OneMonth);
        uint256 monthTokenId = staking.deposit(1 ether, TimeLockedStakingNFT.LockPeriod.OneMonth);
        TimeLockedStakingNFT.Position memory monthPos = staking.getPosition(monthTokenId);
        assertEq(monthPos.entryNav, monthNavPartial);
        
        // After 30 days, OneMonth should be fully unlocked
        vm.warp(block.timestamp + 23 days);
        uint256 monthNavFull = staking.getCurrentEffectiveNav(TimeLockedStakingNFT.LockPeriod.OneMonth);
        uint256 monthTokenId2 = staking.deposit(1 ether, TimeLockedStakingNFT.LockPeriod.OneMonth);
        TimeLockedStakingNFT.Position memory monthPos2 = staking.getPosition(monthTokenId2);
        assertEq(monthPos2.entryNav, monthNavFull); // Now fully unlocked
        assertGt(monthPos2.entryNav, monthPos.entryNav); // Should be higher than partial unlock
        
        // But longer tiers still not fully unlocked
        uint256 threeMonthTokenId = staking.deposit(1 ether, TimeLockedStakingNFT.LockPeriod.ThreeMonths);
        TimeLockedStakingNFT.Position memory threeMonthPos = staking.getPosition(threeMonthTokenId);
        uint256 threeMonthNavPartial = staking.getCurrentEffectiveNav(TimeLockedStakingNFT.LockPeriod.ThreeMonths);
        assertEq(threeMonthPos.entryNav, threeMonthNavPartial); // Partially unlocked
    }

    function testMultipleRewardDistributions() public {
        // Initial deposit
        uint256 amount = 1000 ether;
        uint256 firstWarp=block.timestamp+60*60*24*15;
        uint256 secondWarp=block.timestamp+60*60*24*30;
        uint256 thirdWarp=block.timestamp+60*60*24*60;

        staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);
        
        // First reward distribution
        uint256 reward1 = 100 ether;
        token.mint(address(rewardSource), reward1);
        staking.distributeRewards(reward1);
        
        // Wait 15 days (half of unlock duration)
        vm.warp(firstWarp);
        
        // Second reward distribution while first is still partially locked
        uint256 reward2 = 200 ether;
        token.mint(address(rewardSource), reward2);
        staking.distributeRewards(reward2);
        
        // New depositor should see partially unlocked first reward + fresh second reward pending
        uint256 navAt15Days = staking.getCurrentEffectiveNav(TimeLockedStakingNFT.LockPeriod.OneMonth);
        uint256 newTokenId = staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);
        TimeLockedStakingNFT.Position memory newPos = staking.getPosition(newTokenId);
        assertEq(newPos.entryNav, navAt15Days);
        
        // After another 15 days, first reward fully unlocked, second half unlocked
        vm.warp(secondWarp);
        uint256 tokenId3 = staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);
        TimeLockedStakingNFT.Position memory pos3 = staking.getPosition(tokenId3);
        
        assertGt(pos3.entryNav, newPos.entryNav); // More rewards unlocked
        
        // After total 60 days from start, all rewards should be unlocked
        vm.warp(thirdWarp);
        uint256 tokenId4 = staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);
        TimeLockedStakingNFT.Position memory pos4 = staking.getPosition(tokenId4);
        
        assertGt(pos4.entryNav, pos3.entryNav); // All rewards unlocked
    }

    function testNewDepositsUseBaseNavImmediatelyAfterReward() public {
        vm.warp(0);
        uint256 amount = 1000 ether;
        staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);

        uint256 reward = 500 ether;
        token.mint(address(rewardSource), reward);
        staking.distributeRewards(reward);

        uint256 expectedNav = _expectedEffectiveNavFromState(TimeLockedStakingNFT.LockPeriod.OneMonth, block.timestamp);
        uint256 tokenId2 = staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);
        TimeLockedStakingNFT.Position memory pos2 = staking.getPosition(tokenId2);

        assertEq(pos2.entryNav, expectedNav);
    }

    function testNewDepositsSeePartialUnlockAfterHalfDuration() public {
        vm.warp(0);
        uint256 amount = 1000 ether;
        staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);

        uint256 reward = 500 ether;
        token.mint(address(rewardSource), reward);
        staking.distributeRewards(reward);

        uint256 distributionTimestamp = block.timestamp;
        uint256 halfElapsed = UNLOCK_DURATION_ONE_MONTH / 2;
        vm.warp(distributionTimestamp + halfElapsed);

        uint256 expectedNav = _expectedEffectiveNavFromState(TimeLockedStakingNFT.LockPeriod.OneMonth, block.timestamp);
        uint256 tokenId2 = staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);
        TimeLockedStakingNFT.Position memory pos2 = staking.getPosition(tokenId2);

        assertEq(pos2.entryNav, expectedNav);
    }

    function testNewDepositsSeeFullNavAfterUnlockDuration() public {
        vm.warp(0);
        uint256 amount = 1000 ether;
        staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);

        uint256 reward = 500 ether;
        token.mint(address(rewardSource), reward);
        staking.distributeRewards(reward);

        uint256 distributionTimestamp = block.timestamp;
        vm.warp(distributionTimestamp + UNLOCK_DURATION_ONE_MONTH);

        uint256 expectedNav = _expectedEffectiveNavFromState(TimeLockedStakingNFT.LockPeriod.OneMonth, block.timestamp);
        uint256 tokenId2 = staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);
        TimeLockedStakingNFT.Position memory pos2 = staking.getPosition(tokenId2);

        assertEq(pos2.entryNav, expectedNav);
    }

    function testPendingNavStateUpdatedAcrossDistributions() public {
        uint256 t0=0;
        vm.warp(t0);
        uint256 amount = 1000 ether;
        staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);

        uint256 reward1 = 600 ether;
        token.mint(address(rewardSource), reward1);
        staking.distributeRewards(reward1);

        (uint256 pendingDelta, uint256 lastReport, uint256 duration) = staking.tierPendingNav(
            TimeLockedStakingNFT.LockPeriod.OneMonth
        );
        uint256 expectedDelta1 = Math.mulDiv(reward1, PRECISION, amount);
        assertEq(pendingDelta, expectedDelta1);

        uint256 halfElapsed = duration / 2;
        uint256 t1=t0 + halfElapsed;
        vm.warp(t1);


        uint256 reward2 = 300 ether;
        uint256 remainingPending = pendingDelta - _unlockedNavDeltaAt(pendingDelta, lastReport, duration, t1);
        token.mint(address(rewardSource), reward2);
        staking.distributeRewards(reward2);

        (pendingDelta, lastReport,) = staking.tierPendingNav(TimeLockedStakingNFT.LockPeriod.OneMonth);
        uint256 expectedDelta2 = Math.mulDiv(reward2, PRECISION, amount);
        uint256 expectedAfterSecond = remainingPending + expectedDelta2;
        assertEq(pendingDelta, expectedAfterSecond);

        uint256 t2=t1 + duration;
        vm.warp(t2);

        uint256 reward3 = 200 ether;
        uint256 remainingAfterFull = pendingDelta - _unlockedNavDeltaAt(pendingDelta, lastReport, duration, t2);

        // Ensure there are active shares for the next reward distribution
        uint256 tokenIdNew = staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);
        TimeLockedStakingNFT.Position memory newPosition = staking.getPosition(tokenIdNew);
        uint256 activeShares = newPosition.sharesAmount;

        token.mint(address(rewardSource), reward3);
        staking.distributeRewards(reward3);

        (pendingDelta,,) = staking.tierPendingNav(TimeLockedStakingNFT.LockPeriod.OneMonth);
        uint256 expectedDelta3 = Math.mulDiv(reward3, PRECISION, activeShares);
        assertEq(pendingDelta, remainingAfterFull + expectedDelta3);
    }

    function testGetUserLockPowahWithLockedProfit() public {
        vm.warp(0);

        uint256 amount = 1000 ether;
        uint256 tokenId = staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneMonth);
        TimeLockedStakingNFT.Position memory pos = staking.getPosition(tokenId);
        TimeLockedStakingNFT.LockPeriod lockPeriod = TimeLockedStakingNFT.LockPeriod.OneMonth;

        uint256 expectedInitial = _expectedPowahFromState(lockPeriod, pos.sharesAmount, block.timestamp);
        assertEq(staking.getUserLockPowah(address(this)), expectedInitial);

        uint256 reward = 500 ether;
        token.mint(address(rewardSource), reward);
        staking.distributeRewards(reward);

        uint256 distributionTimestamp = block.timestamp;
        // Immediately after distribution every wei of profit is locked
        uint256 expectedAfterReward = _expectedPowahFromState(lockPeriod, pos.sharesAmount, block.timestamp);
        assertEq(staking.getUserLockPowah(address(this)), expectedAfterReward);

        uint256 halfElapsed = UNLOCK_DURATION_ONE_MONTH / 2;
        vm.warp(distributionTimestamp + halfElapsed);
        uint256 expectedHalf = _expectedPowahFromState(lockPeriod, pos.sharesAmount, block.timestamp);
        assertEq(staking.getUserLockPowah(address(this)), expectedHalf);

        uint256 almostUnlock = pos.unlockTimestamp - 1;
        vm.warp(almostUnlock);
        uint256 expectedBeforeUnlock = _expectedPowahFromState(lockPeriod, pos.sharesAmount, block.timestamp);
        assertEq(staking.getUserLockPowah(address(this)), expectedBeforeUnlock);

        vm.warp(pos.unlockTimestamp + 1);
        assertEq(staking.getUserLockPowah(address(this)), 0);
    }
}
