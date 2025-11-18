// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC721Receiver} from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import {TimeLockedStakingNFT} from "../src/TimeLockedStakingNFT.sol";
import {SUSHIPOWAH} from "../src/SUSHIPOWAH.sol";
import {ITimeLockedStakingNFT} from "../src/interfaces/ITimeLockedStakingNFT.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SushiPowahMainnetForkTest is Test, IERC721Receiver {
    MockToken internal token;
    TimeLockedStakingNFT internal staking;
    SUSHIPOWAH internal sushiPowah;

    address internal constant BOB = address(0xB0b0000000000000000000000000000000000000);
    uint256 internal newTime;
    function setUp() public {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl, 23_827_098);
        newTime = block.timestamp;

        token = new MockToken();
        staking = new TimeLockedStakingNFT(token);
        sushiPowah = new SUSHIPOWAH();

        token.mint(address(this), 1_000 ether);
        token.approve(address(staking), type(uint256).max);

        token.mint(BOB, 1_000 ether);
        vm.prank(BOB);
        token.approve(address(staking), type(uint256).max);
        vm.warp(newTime + 1);
    }

    function testSushiPowahTracksTimeLockedPowah() public {
        //staking.getUserLockPowah(address(this));
        uint256 weekToken = staking.deposit(100 ether, TimeLockedStakingNFT.LockPeriod.OneWeek);
        staking.deposit(200 ether, TimeLockedStakingNFT.LockPeriod.OneMonth);
        vm.warp(newTime + 2);
        vm.startPrank(BOB);
        staking.deposit(300 ether, TimeLockedStakingNFT.LockPeriod.OneWeek);
        vm.stopPrank();

        assertEq(staking.getUserLockPowah(address(this)), 300 ether);
        assertEq(sushiPowah.balanceOf(address(this)), 300 ether);

        assertEq(staking.getUserLockPowah(BOB), 300 ether);
        assertEq(sushiPowah.balanceOf(BOB), 300 ether);

        TimeLockedStakingNFT.Position memory weekPosition = staking.getPosition(weekToken);
        console.log("weekPosition.unlockTimestamp", weekPosition.unlockTimestamp);
        vm.warp(weekPosition.unlockTimestamp - 1);
        assertEq(staking.getUserLockPowah(address(this)), 300 ether);
        assertEq(sushiPowah.balanceOf(address(this)), 300 ether);

        vm.warp(weekPosition.unlockTimestamp + 1);

        assertEq(staking.getUserLockPowah(address(this)), 0 ether);
        assertEq(sushiPowah.balanceOf(address(this)), 0 ether);

        assertEq(staking.getUserLockPowah(BOB), 0);
        assertEq(sushiPowah.balanceOf(BOB), 0);
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
