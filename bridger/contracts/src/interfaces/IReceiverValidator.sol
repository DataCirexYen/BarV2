// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IReceiverValidator {
    function validateReceiver(bytes calldata data) external view returns (bool);
}
