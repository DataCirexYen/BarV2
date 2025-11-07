// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TokenChwomper} from "../src/mocks/TokenChwomper.sol";
import {RevenueBridger} from "../src/revenueBridger.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

contract RevenueBridgerFlowTest is Test {
    address private constant IMPERSONATED = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    address private constant RED_SNWAPPER = 0xAC4c6e212A361c968F1725b4d055b47E63F80b75;
    address private constant MAINNET_RECEIVER = 0xEaA2236C6c998c6520593370dE4195DE23DB159E;
    address private constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address private constant BASE_USDC = 0x833589fCD6edC40Ba2d4b07a5079c7B0ab3b12f3;
    address private constant LIFI_DIAMOND = 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE;
    string private constant BASE_RPC_ENV = "BASE_RPC_URL";

    function setUp() public {
        string memory rpcUrl = vm.envString(BASE_RPC_ENV);
        vm.createSelectFork(rpcUrl);
    }

    function testDeploymentFlow() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(IMPERSONATED);
        TokenChwomper tokenChwomper = new TokenChwomper(IMPERSONATED, RED_SNWAPPER, BASE_WETH);
        vm.stopPrank();

        deal(BASE_WETH, IMPERSONATED, depositAmount);

        vm.prank(IMPERSONATED);
        IERC20(BASE_WETH).transfer(address(tokenChwomper), depositAmount);

        vm.prank(IMPERSONATED);
        RevenueBridger revenueBridger =
            new RevenueBridger(IMPERSONATED, address(tokenChwomper), MAINNET_RECEIVER, BASE_USDC, LIFI_DIAMOND, address(0));

        assertEq(IERC20(BASE_WETH).balanceOf(address(tokenChwomper)), depositAmount);
        assertEq(revenueBridger.owner(), IMPERSONATED);
        assertEq(address(revenueBridger.chwomper()), address(tokenChwomper));
        assertEq(revenueBridger.mainnetReceiver(), MAINNET_RECEIVER);
        assertEq(revenueBridger.usdc(), BASE_USDC);
        assertEq(revenueBridger.liFiDiamond(), LIFI_DIAMOND);
    }
}
