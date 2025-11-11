// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TimeLockedStakingNFT} from "../src/TimeLockedStakingNFT.sol";

contract DeployTimeLockedStakingNFT is Script {
    function run() external {
        address stakingToken = vm.envAddress("STAKING_TOKEN");

        uint256[] memory boostFactors = new uint256[](3);
        boostFactors[0] = 100; // 1.00x weight for day tier
        boostFactors[1] = 105; // 1.05x weight for week tier
        boostFactors[2] = 110; // 1.10x weight for month tier

        vm.startBroadcast();
        new TimeLockedStakingNFT(IERC20(stakingToken), boostFactors);
        vm.stopBroadcast();
    }
}
