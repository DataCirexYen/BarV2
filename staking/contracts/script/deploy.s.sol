// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TimeLockedStakingNFT} from "../src/TimeLockedStakingNFT.sol";

contract DeployTimeLockedStakingNFT is Script {
    function run() external {
        address stakingToken = vm.envAddress("STAKING_TOKEN");

        vm.startBroadcast();
        new TimeLockedStakingNFT(IERC20(stakingToken));
        vm.stopBroadcast();
    }
}
