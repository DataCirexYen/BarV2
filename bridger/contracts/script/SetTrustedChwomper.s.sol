// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TokenChwomper} from "../src/mocks/TokenChwomper.sol";

/// @notice Script to set a trusted address on an existing TokenChwomper contract
/// @dev Environment variables:
///  - DEPLOYER_PRIVATE_KEY: Private key of the owner account
///  - TOKEN_CHWOMPER_ADDRESS: Address of the deployed TokenChwomper contract
///  - TRUSTED_ADDRESS: (optional) Address to trus //bridger
contract SetTrustedChwomperScript is Script {

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tokenChwomperAddress = vm.envAddress("TOKEN_CHWOMPER_ADDRESS");
        address trustedAddress = vm.envOr("BRIDGER", address(0));

        TokenChwomper tokenChwomper = TokenChwomper(payable(tokenChwomperAddress));

        console2.log("TokenChwomper address:", address(tokenChwomper));
        console2.log("Current owner:", tokenChwomper.owner());
        console2.log("Address to trust:", trustedAddress);
        console2.log("Currently trusted:", tokenChwomper.trusted(trustedAddress));

        vm.startBroadcast(deployerKey);
        tokenChwomper.setTrusted(trustedAddress, true);
        vm.stopBroadcast();

        console2.log("Address successfully set as trusted");
        console2.log("Verification - trusted status:", tokenChwomper.trusted(trustedAddress));
    }
}
