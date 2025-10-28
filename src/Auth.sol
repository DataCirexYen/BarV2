// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Auth {
    error OnlyOwner();
    error OnlyTrusted();

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SetTrusted(address indexed user, bool isTrusted);

    address public owner;
    address public pendingOwner;
    mapping(address => bool) public trusted;

    constructor(address operator_) {
        owner = msg.sender;
        if (operator_ != address(0)) {
            trusted[operator_] = true;
            emit SetTrusted(operator_, true);
        }
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyTrusted() {
        if (!trusted[msg.sender]) revert OnlyTrusted();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        address newOwner = pendingOwner;
        if (msg.sender != newOwner || newOwner == address(0)) revert OnlyOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
        pendingOwner = address(0);
    }

    function setTrusted(address user, bool isTrusted) external onlyOwner {
        trusted[user] = isTrusted;
        emit SetTrusted(user, isTrusted);
    }
}
