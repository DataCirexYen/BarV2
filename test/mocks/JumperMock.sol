// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @dev Minimal Jumper mock that pulls the caller's full balance and forwards it to a receiver.
contract JumperMock {
    IERC20 public immutable token;
    address public immutable receiver;

    error TransferFailed();

    constructor(address token_, address receiver_) {
        token = IERC20(token_);
        receiver = receiver_;
    }

    fallback() external payable {
        _bridge();
    }

    receive() external payable {
        _bridge();
    }

    function _bridge() internal {
        uint256 amount = token.balanceOf(msg.sender);
        if (amount == 0) return;

        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(0x23b872dd, msg.sender, receiver, amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
