// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20 as IERC20_OZ} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IERC20} from "./interfaces/IERC20.sol";
import {IRedSnwapper} from "./interfaces/IRedSnwapper.sol";
import {ITokenChwomper} from "./interfaces/ITokenChwomper.sol";

/**
 * @title RevenueBridger
 * @notice Bridges revenue by swapping tokens through Chwomper and forwarding USDC to a mainnet recipient.
 * @dev OWNER manages configuration and rescues; TRUSTER can only call {swapAndBridge}.
 */
contract RevenueBridger is OwnableRoles, ReentrancyGuard {
    using SafeERC20 for IERC20_OZ;
    using FixedPointMathLib for uint256;

    error RevenueBridger__InvalidAddress();
    error RevenueBridger__ExternalCallFailed(bytes revertData);
    error RevenueBridger__InsufficientNative(uint256 requested, uint256 available);
    error RevenueBridger__InvalidSwapParams();
    error RevenueBridger__MissingUsdcOutput();
    error RevenueBridger__InsufficientUsdc(uint256 expected, uint256 actual);
    error RevenueBridger__InvalidCallTarget();

    /// @dev Role bit for trusted actors permitted to call {swapAndBridge}.
    uint256 internal constant TRUSTER_ROLE = _ROLE_0;

    /// @notice Emitted when the contract owner changes.
    event OwnerUpdated(address indexed newOwner);

    /// @notice Emitted when the mainnet revenue recipient changes.
    event MainnetRecipientUpdated(address indexed newRecipient);

    /// @notice Emitted when the USDC token address changes.
    event UsdcUpdated(address indexed newUsdc);

    /// @notice Emitted when the LiFi Diamond contract address changes.
    event LiFiDiamondUpdated(address indexed newLiFiDiamond);

    /// @notice Emitted when an account's truster role is toggled.
    event TrusterUpdated(address indexed account, bool indexed isTrusted);

    /// @notice Emitted after USDC is bridged via an external call.
    event RevenueBridged(
        address indexed token,
        uint256 amount,
        address indexed recipient,
        address callTarget,
        bytes callData
    );

    /// @notice Chwomper aggregator responsible for executing swaps.
    ITokenChwomper public immutable chwomper;

    /// @notice Recipient of bridged revenue on the destination chain.
    address public mainnetRecipient;

    /// @notice USDC token used as the bridge asset.
    address public usdc;

    /// @notice LiFi diamond contract that performs the bridge call.
    address public liFiDiamond;

    /**
     * @notice Initializes the contract with core configuration.
     * @param _owner Initial contract owner.
     * @param _chwomper Chwomper swapper implementation.
     * @param _mainnetRecipient Optional initial mainnet recipient.
     * @param _usdc Optional initial USDC token address.
     * @param _liFiDiamond Optional initial LiFi diamond call target.
     */
    constructor(
        address _owner,
        address _chwomper,
        address _mainnetRecipient,
        address _usdc,
        address _liFiDiamond
    ) {
        if (_owner == address(0) || _chwomper == address(0)) {
            revert RevenueBridger__InvalidAddress();
        }

        _initializeOwner(_owner);
        chwomper = ITokenChwomper(_chwomper);

        if (_mainnetRecipient != address(0)) {
            mainnetRecipient = _mainnetRecipient;
        }

        if (_usdc != address(0)) {
            usdc = _usdc;
        }

        if (_liFiDiamond != address(0)) {
            liFiDiamond = _liFiDiamond;
            emit LiFiDiamondUpdated(_liFiDiamond);
        }
    }

    /**
     * @notice Updates the contract owner.
     * @param _newOwner Address of the new owner.
     */
    function setOwner(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert RevenueBridger__InvalidAddress();
        transferOwnership(_newOwner);
        emit OwnerUpdated(_newOwner);
    }

    /**
     * @notice Updates the mainnet revenue recipient.
     * @param _recipient Address of the new recipient.
     */
    function setMainnetRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert RevenueBridger__InvalidAddress();
        mainnetRecipient = _recipient;
        emit MainnetRecipientUpdated(_recipient);
    }

    /**
     * @notice Updates the USDC token address.
     * @param _usdc Address of the new USDC token.
     */
    function setUsdc(address _usdc) external onlyOwner {
        if (_usdc == address(0)) revert RevenueBridger__InvalidAddress();
        usdc = _usdc;
        emit UsdcUpdated(_usdc);
    }

    /**
     * @notice Updates the LiFi diamond contract address.
     * @param _liFiDiamond Address of the new LiFi diamond contract.
     */
    function setLiFiDiamond(address _liFiDiamond) external onlyOwner {
        if (_liFiDiamond == address(0)) revert RevenueBridger__InvalidAddress();
        liFiDiamond = _liFiDiamond;
        emit LiFiDiamondUpdated(_liFiDiamond);
    }

    /**
     * @notice Grants or revokes the TRUSTER role.
     * @param account Address whose role is being updated.
     * @param isTrusted True to grant access to {swapAndBridge}, false to revoke.
     */
    function setTruster(address account, bool isTrusted) external onlyOwner {
        if (account == address(0)) revert RevenueBridger__InvalidAddress();

        bool currentlyTrusted = hasAllRoles(account, TRUSTER_ROLE);
        if (isTrusted == currentlyTrusted) {
            return;
        }

        if (isTrusted) {
            grantRoles(account, TRUSTER_ROLE);
        } else {
            revokeRoles(account, TRUSTER_ROLE);
        }

        emit TrusterUpdated(account, isTrusted);
    }

    /**
     * @notice Swaps input tokens to USDC through Chwomper and forwards the proceeds.
     * @dev Callable by OWNER or TRUSTER. Calldata must forward USDC to `mainnetRecipient`.
     */
    function swapAndBridge(
        IRedSnwapper.InputToken[] calldata inputTokens,
        IRedSnwapper.OutputToken[] calldata outputTokens,
        IRedSnwapper.Executor[] calldata executors,
        uint256 minUsdcOut,
        address callTarget,
        bytes calldata callData,
        uint256 nativeValue
    )
        external
        payable
        onlyOwnerOrRoles(TRUSTER_ROLE)
        nonReentrant
        returns (bytes memory result)
    {
        if (inputTokens.length == 0 || outputTokens.length == 0) {
            revert RevenueBridger__InvalidSwapParams();
        }
        if (callTarget == address(0)) revert RevenueBridger__InvalidAddress();

        address usdcToken = usdc;
        if (usdcToken == address(0) || mainnetRecipient == address(0)) {
            revert RevenueBridger__InvalidAddress();
        }

        if (liFiDiamond == address(0) || callTarget != liFiDiamond) {
            revert RevenueBridger__InvalidCallTarget();
        }

        _validateOutputs(outputTokens, usdcToken);

        uint256 received = _executeSwap(inputTokens, outputTokens, executors, usdcToken);
        if (received == 0 || received < minUsdcOut) {
            revert RevenueBridger__InsufficientUsdc(minUsdcOut, received);
        }

        _approveToken(usdcToken, callTarget, received);

        if (nativeValue > address(this).balance) {
            revert RevenueBridger__InsufficientNative(nativeValue, address(this).balance);
        }

        bool success;
        (success, result) = callTarget.call{value: nativeValue}(callData);
        if (!success) revert RevenueBridger__ExternalCallFailed(result);

        emit RevenueBridged(usdcToken, received, mainnetRecipient, callTarget, callData);
        return result;
    }

    /**
     * @notice Allows the owner to rescue stranded ERC20 tokens.
     * @param token ERC20 token address.
     * @param to Recipient of the rescued tokens.
     */
    function rescueToken(address token, address to) external onlyOwner {
        if (token == address(0) || to == address(0)) revert RevenueBridger__InvalidAddress();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return;
        IERC20_OZ(token).safeTransfer(to, balance);
    }

    /**
     * @notice Allows the owner to rescue native ETH.
     * @param to Recipient of the rescued ETH.
     */
    function rescueNative(address payable to) external onlyOwner {
        if (to == address(0)) revert RevenueBridger__InvalidAddress();
        uint256 balance = address(this).balance;
        if (balance == 0) return;
        SafeTransferLib.safeTransferETH(to, balance);
    }

    /// @notice Accepts native deposits to fund swap execution or bridging fees.
    receive() external payable {}

    function _executeSwap(
        IRedSnwapper.InputToken[] calldata inputTokens,
        IRedSnwapper.OutputToken[] calldata outputTokens,
        IRedSnwapper.Executor[] calldata executors,
        address usdcToken
    ) internal returns (uint256 received) {
        uint256 balanceBefore = IERC20(usdcToken).balanceOf(address(this));
        chwomper.snwapMultiple(inputTokens, outputTokens, executors);
        uint256 balanceAfter = IERC20(usdcToken).balanceOf(address(this));

        received = balanceAfter.zeroFloorSub(balanceBefore);
    }

    function _validateOutputs(
        IRedSnwapper.OutputToken[] calldata outputTokens,
        address usdcToken
    ) internal view {
        uint256 length = outputTokens.length;
        for (uint256 i; i < length;) {
            IRedSnwapper.OutputToken calldata output = outputTokens[i];
            if (output.token == usdcToken && output.recipient == address(this)) {
                return;
            }
            unchecked {
                ++i;
            }
        }
        revert RevenueBridger__MissingUsdcOutput();
    }

    function _approveToken(address token, address spender, uint256 amount) internal {
        IERC20 erc20Token = IERC20(token);
        uint256 allowance = erc20Token.allowance(address(this), spender);
        if (allowance >= amount) {
            return;
        }

        if (allowance != 0) {
            SafeTransferLib.safeApprove(token, spender, 0);
        }
        SafeTransferLib.safeApprove(token, spender, type(uint256).max);
    }
    /// @notice Fallback function to receive plain ETH transfers.
    fallback() external payable {}
}
