// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title RewardSource
 * @notice Holds incentive tokens and manages allowances for the staking contract.
 */
contract RewardSource is Ownable {
    using SafeERC20 for IERC20;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error ZeroAddress();
    error InvalidAmount();

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event AllowanceSet(address indexed spender, uint256 amount);
    event Funded(address indexed funder, uint256 amount);
    event TokensRecovered(address indexed to, uint256 amount);

    /// -----------------------------------------------------------------------
    /// Storage
    /// -----------------------------------------------------------------------

    IERC20 public immutable rewardToken;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(IERC20 rewardToken_) Ownable(msg.sender) {
        if (address(rewardToken_) == address(0)) {
            revert ZeroAddress();
        }
        rewardToken = rewardToken_;
    }

    /// -----------------------------------------------------------------------
    /// Owner actions
    /// -----------------------------------------------------------------------

    /**
     * @notice Set the allowance for the staking contract (or any spender).
     */
    function setAllowance(address spender, uint256 amount) external onlyOwner {
        if (spender == address(0)) {
            revert ZeroAddress();
        }
        rewardToken.forceApprove(spender, amount);
        emit AllowanceSet(spender, amount);
    }

    /**
     * @notice Withdraw tokens back to the owner or another address.
     */
    function recover(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert InvalidAmount();
        }
        rewardToken.safeTransfer(to, amount);
        emit TokensRecovered(to, amount);
    }

    /// -----------------------------------------------------------------------
    /// Public actions
    /// -----------------------------------------------------------------------

    /**
     * @notice Pull reward tokens into this contract.
     */
    function fund(uint256 amount) external {
        if (amount == 0) {
            revert InvalidAmount();
        }
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }
}
