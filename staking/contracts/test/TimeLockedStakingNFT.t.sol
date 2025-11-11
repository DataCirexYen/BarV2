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
    uint256 internal constant DAY_BOOST = 100; // baseline 1.00x
    uint256 internal constant WEEK_BOOST = 105; // 1.05x relative weight
    uint256 internal constant MONTH_BOOST = 110; // 1.10x relative weight

    function setUp() public {
        token = new MockToken();
        staking = new TimeLockedStakingNFT(token, _defaultBoostFactors());
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

        uint256 entryNav = staking.navPerTierAtSlot(
            TimeLockedStakingNFT.LockPeriod.OneWeek, _floorTimestamp(block.timestamp, 1 weeks)
        );

        assertEq(uint256(position.lockPeriod), uint256(TimeLockedStakingNFT.LockPeriod.OneWeek));
        assertEq(position.startTimestamp, block.timestamp);
        uint256 expectedSlot = _nextSlot(block.timestamp, 1 weeks);
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
        uint256 tokenId = staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneDay);

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

        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneDay), 0);
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
        uint256 dayAmount = 100 ether;
        uint256 weekAmount = 200 ether;
        uint256 monthAmount = 300 ether;

        uint256 dayTokenId = staking.deposit(dayAmount, TimeLockedStakingNFT.LockPeriod.OneDay);
        uint256 weekTokenId = staking.deposit(weekAmount, TimeLockedStakingNFT.LockPeriod.OneWeek);
        uint256 monthTokenId = staking.deposit(monthAmount, TimeLockedStakingNFT.LockPeriod.OneMonth);

        uint256 totalShares = dayAmount + weekAmount + monthAmount;
        uint256 totalReward = 300 ether;
        token.mint(address(rewardSource), totalReward);

        console.log("Total shares before rewards", totalShares);
        console.log("Reward source balance before distribute", token.balanceOf(address(rewardSource)));

        staking.distributeRewards(totalReward);

        uint256 daySlot = _floorTimestamp(block.timestamp, 1 days);
        uint256 weekSlot = _floorTimestamp(block.timestamp, 1 weeks);
        uint256 nextDaySlot = daySlot + 1 days;
        uint256 nextWeekSlot = weekSlot + 1 weeks;
        uint256 nextMonthSlot = _floorTimestamp(block.timestamp, 4 weeks) + 4 weeks;
        console.log("currentWeekSlot", weekSlot);
        console.log("navPerTier day", staking.navPerTier(TimeLockedStakingNFT.LockPeriod.OneDay));

        uint256 dayWeighted = dayAmount * DAY_BOOST;
        uint256 weekWeighted = weekAmount * WEEK_BOOST;
        uint256 monthWeighted = monthAmount * MONTH_BOOST;
        uint256 totalWeighted = dayWeighted + weekWeighted + monthWeighted;

        uint256 dayReward = Math.mulDiv(totalReward, dayWeighted, totalWeighted);
        uint256 weekReward = Math.mulDiv(totalReward, weekWeighted, totalWeighted);
        uint256 monthReward = Math.mulDiv(totalReward, monthWeighted, totalWeighted);

        uint256 dayNavDelta = Math.mulDiv(dayReward, PRECISION, dayAmount);
        uint256 weekNavDelta = Math.mulDiv(weekReward, PRECISION, weekAmount);
        uint256 monthNavDelta = Math.mulDiv(monthReward, PRECISION, monthAmount);

        assertEq(
            staking.navPerTierAtSlot(TimeLockedStakingNFT.LockPeriod.OneDay, nextDaySlot), PRECISION + dayNavDelta
        );
        assertEq(
            staking.navPerTierAtSlot(TimeLockedStakingNFT.LockPeriod.OneWeek, nextWeekSlot), PRECISION + weekNavDelta
        );
        assertEq(
            staking.navPerTierAtSlot(TimeLockedStakingNFT.LockPeriod.OneMonth, nextMonthSlot), PRECISION + monthNavDelta
        );
        assertEq(staking.navPerTier(TimeLockedStakingNFT.LockPeriod.OneDay), PRECISION + dayNavDelta);
        assertEq(staking.navPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek), PRECISION + weekNavDelta);
        assertEq(staking.navPerTier(TimeLockedStakingNFT.LockPeriod.OneMonth), PRECISION + monthNavDelta);

        uint256 expectedDust = totalReward - (dayReward + weekReward + monthReward);
        assertEq(staking.rewardDust(), expectedDust);
        assertEq(token.balanceOf(address(rewardSource)), 0);

        TimeLockedStakingNFT.Position memory monthPosition = staking.getPosition(monthTokenId);

        vm.warp(monthPosition.unlockTimestamp + 1);

        staking.withdraw(dayTokenId);
        staking.withdraw(monthTokenId);
        staking.withdraw(weekTokenId);

        uint256 payoutDay = Math.mulDiv(dayAmount, PRECISION + dayNavDelta, PRECISION);
        uint256 payoutWeek = Math.mulDiv(weekAmount, PRECISION + weekNavDelta, PRECISION);
        uint256 payoutMonth = Math.mulDiv(monthAmount, PRECISION + monthNavDelta, PRECISION);
        uint256 expectedBalance = (1_000 ether - totalShares) + payoutDay + payoutWeek + payoutMonth;
        assertEq(token.balanceOf(address(this)), expectedBalance);
        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneDay), 0);
        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek), 0);
        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneMonth), 0);
    }

    function testDayTierNavCheckpointNotStoredWhenNoShares() public {
        // Create and withdraw all share positions, so there are 0 total shares
        uint256 dayTokenId = staking.deposit(100 ether, TimeLockedStakingNFT.LockPeriod.OneDay);
        uint256 weekTokenId = staking.deposit(200 ether, TimeLockedStakingNFT.LockPeriod.OneWeek);
        TimeLockedStakingNFT.Position memory dayPosition = staking.getPosition(dayTokenId);

        vm.warp(dayPosition.unlockTimestamp + 1 minutes);

        staking.withdraw(dayTokenId);
        staking.withdraw(weekTokenId);

        // Now, all shares are withdrawn, and no shares exist. Attempting to distribute should revert.
        token.mint(address(rewardSource), 200 ether);
        vm.expectRevert(); // Should revert due to no active shares
        staking.distributeRewards(200 ether);
    }

    function testDelayedWithdrawUsesUnlockNav() public {
        uint256 dayAmount = 100 ether;
        uint256 weekAmount = 200 ether;
        uint256 dayTokenId = staking.deposit(dayAmount, TimeLockedStakingNFT.LockPeriod.OneDay);
        staking.deposit(weekAmount, TimeLockedStakingNFT.LockPeriod.OneWeek);
        TimeLockedStakingNFT.Position memory dayPosition = staking.getPosition(dayTokenId);
        uint256 totalReward = 150 ether;
        token.mint(address(rewardSource), totalReward);
        staking.distributeRewards(totalReward);

        vm.warp(dayPosition.unlockTimestamp + 1 minutes);

        uint256 balanceBefore = token.balanceOf(address(this));
        vm.warp(block.timestamp + 3 days);
        staking.withdraw(dayTokenId);
        uint256 balanceAfter = token.balanceOf(address(this));

        uint256 weekShares = staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek);
        uint256 dayShares = dayPosition.sharesAmount;
        uint256 dayWeighted = dayShares * DAY_BOOST;
        uint256 weekWeighted = weekShares * WEEK_BOOST;
        uint256 totalWeighted = dayWeighted + weekWeighted;
        uint256 dayReward = Math.mulDiv(totalReward, dayWeighted, totalWeighted);
        uint256 expectedNav = PRECISION + Math.mulDiv(dayReward, PRECISION, dayShares);
        uint256 expectedPayout = Math.mulDiv(dayShares, expectedNav, PRECISION);

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

    function _defaultBoostFactors() internal pure returns (uint256[] memory factors) {
        factors = new uint256[](3);
        factors[0] = DAY_BOOST;
        factors[1] = WEEK_BOOST;
        factors[2] = MONTH_BOOST;
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
