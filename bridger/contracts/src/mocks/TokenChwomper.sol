// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRedSnwapper} from "../interfaces/IRedSnwapper.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {Auth} from "./Auth.sol";

/// @title TokenChwomper for selling accumulated tokens for WETH or other base assets
/// @notice Contract for fee collection and breakdown managed by trusted operators
contract TokenChwomper is Auth {
    address public immutable weth;
    IRedSnwapper public redSnwapper;

    bytes4 private constant TRANSFER_SELECTOR = bytes4(keccak256("transfer(address,uint256)"));

    error TransferFailed();

    constructor(address _operator, address _redSnwapper, address _weth) Auth(_operator) {
        // deploying account becomes owner via Auth
        redSnwapper = IRedSnwapper(_redSnwapper);
        weth = _weth;
    }

    /// @notice Updates the RedSnwapper to be used for swapping tokens
    /// @dev make sure new RedSnwapper is backwards compatible
    function updateRedSnwapper(address _redSnwapper) external onlyOwner {
        redSnwapper = IRedSnwapper(_redSnwapper);
    }

    /// @notice Swaps a single token via the configured RedSnwapper
    /// @dev Must be called by a trusted operator
    function snwap(
        address tokenIn,
        uint256 amountIn,
        address receiver,
        address tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) external onlyTrusted returns (uint256 amountOut) {
        _safeTransfer(tokenIn, address(redSnwapper), amountIn);

        amountOut = redSnwapper.snwap(tokenIn, 0, receiver, tokenOut, amountOutMin, executor, executorData);
    }

    /// @notice Performs multiple swaps via the configured RedSnwapper
    /// @dev Must be called by a trusted operator
    function snwapMultiple(
        IRedSnwapper.InputToken[] calldata inputTokens,
        IRedSnwapper.OutputToken[] calldata outputTokens,
        IRedSnwapper.Executor[] calldata executors
    ) external onlyTrusted returns (uint256[] memory amountOut) {
        uint256 length = inputTokens.length;
        IRedSnwapper.InputToken[] memory _inputTokens = new IRedSnwapper.InputToken[](length);
        for (uint256 i = 0; i < length; ++i) {
            _safeTransfer(inputTokens[i].token, address(redSnwapper), inputTokens[i].amountIn);
            _inputTokens[i] = IRedSnwapper.InputToken({
                token: inputTokens[i].token,
                amountIn: 0,
                transferTo: inputTokens[i].transferTo
            });
        }

        amountOut = redSnwapper.snwapMultiple(_inputTokens, outputTokens, executors);
    }

    /// @notice Withdraw any token or ETH from the contract
    function withdraw(address token, address to, uint256 value) external onlyOwner {
        if (token != address(0)) {
            _safeTransfer(token, to, value);
        } else {
            (bool success,) = to.call{value: value}("");
            if (!success) revert TransferFailed();
        }
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(TRANSFER_SELECTOR, to, value));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @notice Wrap native ETH into WETH
    function wrapEth() external onlyTrusted {
        (bool success,) = weth.call{value: address(this).balance}("");
        if (!success) revert TransferFailed();
    }

    /// @notice Escape hatch for owner to perform arbitrary calls
    function doAction(address to, uint256 value, bytes memory data) external onlyOwner {
        (bool success,) = to.call{value: value}(data);
        if (!success) revert TransferFailed();
    }

    receive() external payable {}
}
