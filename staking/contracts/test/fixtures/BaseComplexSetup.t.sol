// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TimeLockedStakingNFT} from "../../src/TimeLockedStakingNFT.sol";
import {RewardSource} from "../../src/RewardSource.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {console} from "forge-std/console.sol";

contract MockRewardToken is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @dev Builds a multi-user staking environment with historic deposits,
 * withdrawals and two reward distributions so scenario tests can assume
 * ongoing activity without reimplementing timelines.
 */
abstract contract BaseComplexSetup is Test {
    MockRewardToken internal token;
    TimeLockedStakingNFT internal staking;
    RewardSource internal rewardSource;

    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant DAY_BOOST = 100;
    uint256 internal constant WEEK_BOOST = 105;
    uint256 internal constant MONTH_BOOST = 110;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCAFE);
    address internal constant DAVE = address(0xDAD);
    address internal constant NEW_USER = address(0xFEED);

    uint256 internal constant ALICE_INITIAL_DEPOSIT = 400 ether;
    uint256 internal constant CAROL_MONTHLY_DEPOSIT = 600 ether;
    uint256 internal constant DAVE_MONTHLY_DEPOSIT = 500 ether;
    uint256 internal constant BOB_DAYLOCK_DEPOSIT = 180 ether;
    uint256 internal constant ALICE_RENEWED_DEPOSIT = 250 ether;

    uint256 internal constant FIRST_REWARD = 360 ether;
    uint256 internal constant SECOND_REWARD = 210 ether;

    uint256 internal aliceWeekTokenId;
    uint256 internal carolMonthTokenId;
    uint256 internal daveMonthTokenId;
    uint256 internal bobDayTokenId;
    uint256 internal aliceRenewedWeekTokenId;

    function setUp() public virtual {
        token = new MockRewardToken();
        staking = new TimeLockedStakingNFT(token, _defaultBoostFactors());
        rewardSource = new RewardSource(token);

        staking.setRewardSource(address(rewardSource));
        rewardSource.setAllowance(address(staking), type(uint256).max);

        _seedAccount(ALICE);
        _seedAccount(BOB);
        _seedAccount(CAROL);
        _seedAccount(DAVE);
        _seedAccount(NEW_USER);

        token.mint(address(rewardSource), FIRST_REWARD + SECOND_REWARD + 1_000 ether);

        // History leading into the test.
        vm.warp(1 weeks - 3 days);

        vm.prank(ALICE);
        aliceWeekTokenId = staking.deposit(ALICE_INITIAL_DEPOSIT, TimeLockedStakingNFT.LockPeriod.OneWeek);

        vm.warp(block.timestamp + 1 days);
        vm.prank(CAROL);
        carolMonthTokenId = staking.deposit(CAROL_MONTHLY_DEPOSIT, TimeLockedStakingNFT.LockPeriod.OneMonth);

        vm.warp(block.timestamp + 12 hours);
        vm.prank(DAVE);
        daveMonthTokenId = staking.deposit(DAVE_MONTHLY_DEPOSIT, TimeLockedStakingNFT.LockPeriod.OneMonth);

        vm.warp(1 weeks - 30 minutes);
        vm.prank(BOB);
        bobDayTokenId = staking.deposit(BOB_DAYLOCK_DEPOSIT, TimeLockedStakingNFT.LockPeriod.OneDay);

        vm.warp(1 weeks + 5 minutes);
        staking.distributeRewards(FIRST_REWARD);

        TimeLockedStakingNFT.Position memory bobPos = staking.getPosition(bobDayTokenId);
        vm.warp(bobPos.unlockTimestamp + 1);
    
        vm.prank(BOB);
        staking.withdraw(bobDayTokenId);

        vm.warp(3 weeks + 1 hours);
        vm.prank(ALICE);
        aliceRenewedWeekTokenId = staking.deposit(ALICE_RENEWED_DEPOSIT, TimeLockedStakingNFT.LockPeriod.OneWeek);

        vm.warp(3 weeks + 2 hours);
        console.log("pre-distribute-reward timestamp", block.timestamp);
        staking.distributeRewards(SECOND_REWARD); 
        vm.warp(block.timestamp + 20 minutes);
    }

    function _seedAccount(address account) internal {
        token.mint(account, 5_000 ether);
        vm.startPrank(account);
        token.approve(address(staking), type(uint256).max);
        vm.stopPrank();
    }

    function _floorTimestamp(uint256 timestamp, uint256 size) internal pure returns (uint256) {
        return (timestamp / size) * size;
    }

    function _ceilTimestamp(uint256 timestamp, uint256 size) internal pure returns (uint256) {
        return ((timestamp + size - 1) / size) * size;
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
}
