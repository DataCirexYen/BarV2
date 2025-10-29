// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface ILiFi {
    struct BridgeData {
        bytes32 transactionId;
        string bridge;
        string integrator;
        address referrer;
        address receiver;
        address sendingAssetId;
        uint256 minAmount;
        uint256 destinationChainId;
        bool hasSourceSwaps;
        bool hasDestinationCall;
    }
}

contract ReceiverValidator {
    address public immutable RECEIVER_FIXED_ADDRESS;

    constructor(address _fixedReceiver) {
        RECEIVER_FIXED_ADDRESS = _fixedReceiver;
    }

    function validateReceiver(bytes calldata data) external view returns (bool) {
        // All LiFi bridge entrypoints start with 4-byte selector, then _bridgeData
        // We'll decode only the first argument (_bridgeData)
        bytes memory params = data[4:];

        // Decode only the first argument (LiFi always uses BridgeData as first)
        ILiFi.BridgeData memory bridgeData = abi.decode(params, (ILiFi.BridgeData));

        // Compare the receiver
        return bridgeData.receiver == RECEIVER_FIXED_ADDRESS;
    }
}
