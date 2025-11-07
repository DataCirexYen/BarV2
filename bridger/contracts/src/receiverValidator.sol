// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface ILiFi {
    struct BridgeData {
        bytes32 transactionId;
        string bridge;
        string integrator;
        address referrer;
        address sendingAssetId;
        address receiver;
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
        bytes memory params = data[4:];

        ILiFi.BridgeData memory bridgeData = abi.decode(params, (ILiFi.BridgeData));

        return bridgeData.receiver == RECEIVER_FIXED_ADDRESS;
    }
}
