// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRedSnwapper {
    struct InputToken {
        address token;
        uint256 amountIn;
        address transferTo;
    }

    struct OutputToken {
        address token;
        address recipient;
        uint256 amountOutMin;
    }

    struct Executor {
        address executor;
        uint256 value;
        bytes data;
    }

    function snwap(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) external returns (uint256 amountOut);

    function snwapMultiple(
        InputToken[] calldata inputTokens,
        OutputToken[] calldata outputTokens,
        Executor[] calldata executors
    ) external returns (uint256[] memory amountOut);
}
