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

        uint256 entryNav =
            staking.navPerTierAtSlot(TimeLockedStakingNFT.LockPeriod.OneWeek, _floorTimestamp(block.timestamp, WEEK_DURATION));

        assertEq(uint256(position.lockPeriod), uint256(TimeLockedStakingNFT.LockPeriod.OneWeek));
        assertEq(position.startTimestamp, block.timestamp);
        uint256 expectedSlot = _nextSlot(block.timestamp, WEEK_DURATION);
        assertEq(position.unlockTimestamp, expectedSlot);
        assertEq(position.entryNav, PRECISION);
        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek), amount);
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

        staking.distributeRewards(totalReward);

        uint256 weekSlot = _floorTimestamp(block.timestamp, WEEK_DURATION);
        uint256 monthSlot = _floorTimestamp(block.timestamp, MONTH_DURATION);
        uint256 threeMonthSlot = _floorTimestamp(block.timestamp, THREE_MONTH_DURATION);
        uint256 twelveMonthSlot = _floorTimestamp(block.timestamp, TWELVE_MONTH_DURATION);

        uint256 nextWeekSlot = weekSlot + WEEK_DURATION;
        uint256 nextMonthSlot = monthSlot + MONTH_DURATION;
        uint256 nextThreeMonthSlot = threeMonthSlot + THREE_MONTH_DURATION;
        uint256 nextTwelveMonthSlot = twelveMonthSlot + TWELVE_MONTH_DURATION;

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

        assertEq(
            staking.navPerTierAtSlot(TimeLockedStakingNFT.LockPeriod.OneWeek, nextWeekSlot), PRECISION + weekNavDelta
        );
        assertEq(
            staking.navPerTierAtSlot(TimeLockedStakingNFT.LockPeriod.OneMonth, nextMonthSlot), PRECISION + monthNavDelta
        );
        assertEq(
            staking.navPerTierAtSlot(TimeLockedStakingNFT.LockPeriod.ThreeMonths, nextThreeMonthSlot),
            PRECISION + threeMonthNavDelta
        );
        assertEq(
            staking.navPerTierAtSlot(TimeLockedStakingNFT.LockPeriod.TwelveMonths, nextTwelveMonthSlot),
            PRECISION + twelveMonthNavDelta
        );
        assertEq(staking.navPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek), PRECISION + weekNavDelta);
        assertEq(staking.navPerTier(TimeLockedStakingNFT.LockPeriod.OneMonth), PRECISION + monthNavDelta);
        assertEq(staking.navPerTier(TimeLockedStakingNFT.LockPeriod.ThreeMonths), PRECISION + threeMonthNavDelta);
        assertEq(staking.navPerTier(TimeLockedStakingNFT.LockPeriod.TwelveMonths), PRECISION + twelveMonthNavDelta);

        uint256 expectedDust = totalReward - (weekReward + monthReward + threeMonthReward + twelveMonthReward);
        assertEq(staking.rewardDust(), expectedDust);
        assertEq(token.balanceOf(address(rewardSource)), 0);

        TimeLockedStakingNFT.Position memory twelveMonthPosition = staking.getPosition(twelveMonthTokenId);

        vm.warp(twelveMonthPosition.unlockTimestamp + 1);

        staking.withdraw(weekTokenId);
        staking.withdraw(monthTokenId);
        staking.withdraw(threeMonthTokenId);
        staking.withdraw(twelveMonthTokenId);

        uint256 payoutWeek = Math.mulDiv(weekAmount, PRECISION + weekNavDelta, PRECISION);
        uint256 payoutMonth = Math.mulDiv(monthAmount, PRECISION + monthNavDelta, PRECISION);
        uint256 payoutThreeMonth = Math.mulDiv(threeMonthAmount, PRECISION + threeMonthNavDelta, PRECISION);
        uint256 payoutTwelveMonth = Math.mulDiv(twelveMonthAmount, PRECISION + twelveMonthNavDelta, PRECISION);
        uint256 expectedBalance =
            (1_000 ether - totalShares) + payoutWeek + payoutMonth + payoutThreeMonth + payoutTwelveMonth;
        assertEq(token.balanceOf(address(this)), expectedBalance);
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

        vm.warp(weekPosition.unlockTimestamp + 1 minutes);

        uint256 balanceBefore = token.balanceOf(address(this));
        vm.warp(block.timestamp + 3 days);
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
