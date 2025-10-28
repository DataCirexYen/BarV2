// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IRedSnwapper} from "../../src/interfaces/IRedSnwapper.sol";
import {ITokenChwomper} from "../../src/interfaces/ITokenChwomper.sol";

contract TokenChwomperMock is ITokenChwomper {
    error TransferFailed();
    error BalanceMismatch();

    event SnwapMultipleCalled(address indexed caller, uint256 inputCount, uint256 outputCount, uint256 executorCount);

    IERC20 public immutable payoutToken;

    uint256[] private _nextAmountsOut;
    uint256 private _expectedInputReduction;

    constructor(address payoutToken_) {
        payoutToken = IERC20(payoutToken_);
    }

    function setExpectedInputReduction(uint256 amount) external {
        _expectedInputReduction = amount;
    }

    function setNextAmountsOut(uint256[] calldata amounts) external {
        delete _nextAmountsOut;
        for (uint256 i = 0; i < amounts.length; ++i) {
            _nextAmountsOut.push(amounts[i]);
        }
    }

    function snwap(address, uint256, address, address, uint256, address, bytes calldata)
        external
        pure
        override
        returns (uint256 amountOut)
    {
        return amountOut;
    }

    function snwapMultiple(
        IRedSnwapper.InputToken[] calldata inputTokens,
        IRedSnwapper.OutputToken[] calldata outputTokens,
        IRedSnwapper.Executor[] calldata executors
    ) external override returns (uint256[] memory amountOut) {
        uint256 preBalance = inputTokens.length > 0
            ? IERC20(inputTokens[0].token).balanceOf(address(this))
            : 0;

        emit SnwapMultipleCalled(msg.sender, inputTokens.length, outputTokens.length, executors.length);

        for (uint256 i = 0; i < inputTokens.length; ++i) {
            uint256 amountIn = inputTokens[i].amountIn;
            if (amountIn != 0) {
                if (!IERC20(inputTokens[i].token).transfer(inputTokens[i].transferTo, amountIn)) revert TransferFailed();
            }
        }

        uint256 outputsLen = outputTokens.length;
        amountOut = new uint256[](outputsLen);

        for (uint256 i = 0; i < outputsLen; ++i) {
            uint256 payout = i < _nextAmountsOut.length ? _nextAmountsOut[i] : 0;
            amountOut[i] = payout;

            if (payout != 0 && outputTokens[i].token == address(payoutToken)) {
                if (!payoutToken.transfer(outputTokens[i].recipient, payout)) revert TransferFailed();
            }
        }

        delete _nextAmountsOut;

        if (_expectedInputReduction != 0) {
            uint256 postBalance = IERC20(inputTokens[0].token).balanceOf(address(this));
            uint256 diff = preBalance - postBalance;
            if (diff != _expectedInputReduction) revert BalanceMismatch();
            _expectedInputReduction = 0;
        }
    }
}
