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

        uint256 entryNav = staking.navPerTierAtSlot(TimeLockedStakingNFT.LockPeriod.OneWeek, position.startTimestamp);

        assertEq(uint256(position.lockPeriod), uint256(TimeLockedStakingNFT.LockPeriod.OneWeek));
        assertEq(position.startTimestamp, block.timestamp);
        uint256 expectedSlot = ((block.timestamp + 7 days) / 1 weeks) * 1 weeks;
        assertEq(position.unlockTimestamp, expectedSlot);


        assertEq(position.entryNav, 1e18);
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

        console.log("Withdraw test tokenId", tokenId);
        console.log("Fast-forwarding time to", block.timestamp + 1 days + 1);

        vm.warp(block.timestamp + 1 days + 1);
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
        uint256 dayTokenId = staking.deposit(100 ether, TimeLockedStakingNFT.LockPeriod.OneDay);
        uint256 weekTokenId = staking.deposit(200 ether, TimeLockedStakingNFT.LockPeriod.OneWeek);
        uint256 monthTokenId = staking.deposit(300 ether, TimeLockedStakingNFT.LockPeriod.OneMonth);

        uint256 totalShares = 100 ether + 200 ether + 300 ether;
        token.mint(address(rewardSource), 300 ether);

        console.log("Total shares before rewards", totalShares);
        console.log("Reward source balance before distribute", token.balanceOf(address(rewardSource)));

        staking.distributeRewards(300 ether);

        uint256 precision = 1e18;
        uint256 currentSlot = (block.timestamp / 1 weeks) * 1 weeks;
        console.log("currentSlot", currentSlot);
        console.log("navPerTier day", staking.navPerTier(TimeLockedStakingNFT.LockPeriod.OneDay));
        console.log("navAtSlot day", staking.navPerTierAtSlot(TimeLockedStakingNFT.LockPeriod.OneDay, currentSlot));
        uint256 dayReward = Math.mulDiv(300 ether, 100 ether, totalShares);
        uint256 weekReward = Math.mulDiv(300 ether, 200 ether, totalShares);
        uint256 monthReward = Math.mulDiv(300 ether, 300 ether, totalShares);
        uint256 dayNavDelta = Math.mulDiv(dayReward, precision, 100 ether);
        uint256 weekNavDelta = Math.mulDiv(weekReward, precision, 200 ether);
        uint256 monthNavDelta = Math.mulDiv(monthReward, precision, 300 ether);

        assertEq(
            staking.navPerTierAtSlot(TimeLockedStakingNFT.LockPeriod.OneDay, currentSlot), precision + dayNavDelta
        );
        assertEq(
            staking.navPerTierAtSlot(TimeLockedStakingNFT.LockPeriod.OneWeek, currentSlot), precision + weekNavDelta
        );
        assertEq(
            staking.navPerTierAtSlot(TimeLockedStakingNFT.LockPeriod.OneMonth, currentSlot), precision + monthNavDelta
        );
        assertEq(staking.navPerTier(TimeLockedStakingNFT.LockPeriod.OneDay), precision + dayNavDelta);
        assertEq(staking.navPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek), precision + weekNavDelta);
        assertEq(staking.navPerTier(TimeLockedStakingNFT.LockPeriod.OneMonth), precision + monthNavDelta);
        uint256 expectedDust = 300 ether - (dayReward + weekReward + monthReward);
        assertEq(staking.rewardDust(), expectedDust);
        assertEq(token.balanceOf(address(rewardSource)), 0);

        vm.warp(block.timestamp + 31 days + 1);

        staking.withdraw(dayTokenId);
        staking.withdraw(weekTokenId);
        staking.withdraw(monthTokenId);

        uint256 expectedRewards = dayReward + weekReward + monthReward;
        uint256 expectedBalance = 1_000 ether + expectedRewards;
        assertEq(token.balanceOf(address(this)), expectedBalance);
        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneDay), 0);
        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek), 0);
        assertEq(staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneMonth), 0);
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
