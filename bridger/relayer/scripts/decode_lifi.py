#!/usr/bin/env python3
"""Decode LiFi calldata using the shared ABI bundle."""

from pathlib import Path
import sys

from web3 import Web3

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from relayer.contracts import load_contract_abi


lifi_abi = load_contract_abi("lifi_diamond.json")


def decode_call(calldata: str, abi: list[dict]) -> None:
    """Decode the call data using the provided ABI and print the details."""
    data = calldata if calldata.startswith("0x") else f"0x{calldata}"
    w3 = Web3()
    contract = w3.eth.contract(abi=abi)
    function, params = contract.decode_function_input(data)

    print(f"Function: {function.fn_name}")
    for name, value in params.items():
        print(f"{name}: {value}")


if __name__ == "__main__":
    decode_call(output, lifi_abi)
