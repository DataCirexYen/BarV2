// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRedSnwapper} from "./IRedSnwapper.sol";

interface ITokenChwomper {
    function snwap(
        address tokenIn,
        uint256 amountIn,
        address receiver,
        address tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) external returns (uint256 amountOut);

    function snwapMultiple(
        IRedSnwapper.InputToken[] calldata inputTokens,
        IRedSnwapper.OutputToken[] calldata outputTokens,
        IRedSnwapper.Executor[] calldata executors
    ) external returns (uint256[] memory amountOut);
}
