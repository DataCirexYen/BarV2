// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {RevenueBridger} from "../src/revenueBridger.sol";

/// @notice Deploys TokenChwomper + RevenueBridger wired to live Base endpoints.
/// @dev Reads configuration from environment variables when present, otherwise falls back to defaults
///      matching the production setup you shared during testing.
contract DeployRevenueBridgerScript is Script {
    // Base mainnet addresses (defaults)
    struct DeployConfig {
        address owner;
        address chwomper;
        address mainnetRecipient;
        address usdc;
        address liFiDiamond;
        address truster;
    }

    function run() external returns (RevenueBridger revenueBridger) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        DeployConfig memory cfg = _config();
        bool trusterConfigured;

        vm.startBroadcast(deployerKey);

        revenueBridger =
            new RevenueBridger(cfg.owner, cfg.chwomper, cfg.mainnetRecipient, cfg.usdc, cfg.liFiDiamond);

        if (cfg.truster != address(0) && cfg.owner == deployer) {
            revenueBridger.setTruster(cfg.truster, true);
            trusterConfigured = true;
        }

        vm.stopBroadcast();

        _logDeployments(revenueBridger, cfg, trusterConfigured);

        if (cfg.truster != address(0) && cfg.owner != deployer) {
            console2.log(
                "WARNING: truster address provided but not configured. Owner must call setTruster:",
                cfg.truster
            );
        }
    }

    function _config() internal view returns (DeployConfig memory cfg) {
        cfg.owner = vm.envOr("REVENUE_BRIDGER_OWNER");
        cfg.chwomper = vm.envOr("TOKEN_CHWOMPER_ADDRESS");
        cfg.mainnetRecipient = vm.envOr("MAINNET_RECIPIENT_ADDR");
        cfg.usdc = vm.envOr("BASE_USDC_ADDR");
        cfg.liFiDiamond = vm.envOr("LI_FI_DIAMOND_ADDR");
        cfg.truster = vm.envOr("REVENUE_BRIDGER_TRUSTER");
    }

    function _logDeployments(
        RevenueBridger revenueBridger,
        DeployConfig memory cfg,
        bool trusterConfigured
    ) internal view {
        console2.log("RevenueBridger deployed at:", address(revenueBridger));
        console2.log("RevenueBridger owner:", cfg.owner);
        console2.log("Mainnet recipient:", cfg.mainnetRecipient);
        console2.log("TokenChwomper:", cfg.chwomper);
        console2.log("USDC token:", cfg.usdc);
        console2.log("LiFi diamond:", cfg.liFiDiamond);
        console2.log("Configured truster:", trusterConfigured ? cfg.truster : address(0));
    }
}
