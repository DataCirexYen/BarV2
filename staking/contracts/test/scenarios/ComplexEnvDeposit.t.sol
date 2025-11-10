// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {TimeLockedStakingNFT} from "../../src/TimeLockedStakingNFT.sol";
import {BaseComplexSetup} from "../fixtures/BaseComplexSetup.t.sol";

contract ComplexEnvDepositTest is BaseComplexSetup {
    function testEntryNavIsCorrect() public view {
        uint256 currentWeekSlot = _floorTimestamp(block.timestamp, 1 weeks);
        uint256 slot = currentWeekSlot + 1 weeks;
        uint256 nav = staking.navPerTierAtSlot(TimeLockedStakingNFT.LockPeriod.OneWeek, slot);
        assertGt(nav, 0);
        // Optional: matches current accumulator since last distribution was this week
        assertEq(nav, staking.navPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek));
    }
    function testBasicDepositInBusyEnvironment() public {
        uint256 amount = 250 ether;
        uint256 depositorBalanceBefore = token.balanceOf(NEW_USER);
        uint256 stakingBalanceBefore = token.balanceOf(address(staking));
        uint256 weekSharesBefore = staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek);
        uint256 depositTimestamp = block.timestamp;
        vm.prank(NEW_USER);
        uint256 tokenId = staking.deposit(amount, TimeLockedStakingNFT.LockPeriod.OneWeek);

        assertEq(staking.ownerOf(tokenId), NEW_USER);

        TimeLockedStakingNFT.Position memory position = staking.getPosition(tokenId);
        uint256 expectedShares = Math.mulDiv(amount, PRECISION, position.entryNav);
        assertEq(position.sharesAmount, expectedShares);
        assertEq(position.startTimestamp, depositTimestamp);

        uint256 expectedUnlock = _nextSlot(depositTimestamp, 1 weeks);
        assertEq(position.unlockTimestamp, expectedUnlock);

        assertEq(
            staking.totalSharesPerTier(TimeLockedStakingNFT.LockPeriod.OneWeek),
            weekSharesBefore + expectedShares
        );

        assertEq(token.balanceOf(NEW_USER), depositorBalanceBefore - amount);
        assertEq(token.balanceOf(address(staking)), stakingBalanceBefore + amount);
    }
}
