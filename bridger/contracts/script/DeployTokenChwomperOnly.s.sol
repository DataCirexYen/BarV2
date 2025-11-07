// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TokenChwomper} from "../src/mocks/TokenChwomper.sol";

/// @notice Deploys a standalone TokenChwomper configured for Base mainnet defaults.
/// @dev Environment overrides:
///  - TOKEN_CHWOMPER_OPERATOR: trusted operator to seed in Auth (defaults to deployer).
///  - RED_SNWAPPER_ADDR: Router/executor to forward swaps to.
///  - BASE_WETH_ADDR: Wrapped native token address.
contract DeployTokenChwomperOnlyScript is Script {
    address internal constant DEFAULT_RED_SNWAPPER = 0xAC4c6e212A361c968F1725b4d055b47E63F80b75;
    address internal constant DEFAULT_BASE_WETH = 0x4200000000000000000000000000000000000006;

    function run() external returns (TokenChwomper tokenChwomper) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address operator = vm.envOr("TOKEN_CHWOMPER_OPERATOR", vm.addr(deployerKey));
        address redSnwapper = vm.envOr("RED_SNWAPPER_ADDR", DEFAULT_RED_SNWAPPER);
        address weth = vm.envOr("BASE_WETH_ADDR", DEFAULT_BASE_WETH);

        vm.startBroadcast(deployerKey);
        tokenChwomper = new TokenChwomper(operator, redSnwapper, weth);
        vm.stopBroadcast();

        console2.log("TokenChwomper deployed at:", address(tokenChwomper));
        console2.log("Owner:", tokenChwomper.owner());
        console2.log("Trusted operator seeded:", operator);
        console2.log("RedSnwapper:", redSnwapper);
        console2.log("WETH:", weth);
    }
}
