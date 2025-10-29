// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ReceiverValidator} from "../src/receiverValidator.sol";

/// @notice Deploys the ReceiverValidator contract pinned to a fixed receiver.
/// @dev Reads configuration from environment variable: RECEIVER_VALIDATOR_FIXED_RECEIVER
contract DeployReceiverValidatorScript is Script {
    function run() external returns (ReceiverValidator validator) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address fixedReceiver = vm.envAddress("MAINNET_RECEIVER_ADDR");
        require(fixedReceiver != address(0), "ReceiverValidator: receiver missing");

        vm.startBroadcast(deployerKey);
        validator = new ReceiverValidator(fixedReceiver);
        vm.stopBroadcast();

        console2.log("ReceiverValidator deployed at:", address(validator));
        console2.log("Fixed receiver:", fixedReceiver);
    }
}
