"""Quoting utilities for Sushi and Li.Fi (Jumper)."""

from __future__ import annotations

import functools
from typing import Any, Callable, Dict, Optional

import requests
from web3 import Web3

from relayer.config import RelayerConfig
from relayer.contracts import load_contract_abi
from relayer.core.utils import (
    SushiQuoteResult,
    ensure_web3_connected,
    get_logger,
    hex_to_bytes,
)

LOGGER = get_logger("relayer.quotes")


def _load_snwagger_abi() -> list:
    return load_contract_abi("snwaggerabi.json")


@functools.lru_cache(maxsize=1)
def _cached_snwagger_abi() -> list:
    return _load_snwagger_abi()


def _decode_snwap_multiple(raw_data: str) -> Dict[str, Any]:
    from web3 import Web3 as _Web3

    contract = _Web3().eth.contract(abi=_cached_snwagger_abi())
    try:
        fn, params = contract.decode_function_input(hex_to_bytes(raw_data))
        result = {
            "function": fn.fn_name,
            "inputTokens": params["inputTokens"],
            "outputTokens": params["outputTokens"],
            "executors": [],
        }
        for executor in params["executors"]:
            if isinstance(executor, dict):
                data = executor
            else:
                data = {
                    "executor": executor[0],
                    "value": executor[1],
                    "data": executor[2],
                }
            result["executors"].append(
                {
                    "executor": Web3.to_checksum_address(data["executor"]),
                    "value": int(data["value"]),
                    "data": data["data"] if isinstance(data["data"], str) else data["data"].hex(),
                }
            )
        return result
    except Exception as exc:  # pragma: no cover - best effort decode
        raise ValueError(f"Failed to decode snwapMultiple payload: {exc}") from exc


def _decode_snwap(raw_data: str) -> Dict[str, Any]:
    snwap_abi = {
        "inputs": [
            {"internalType": "contract IERC20", "name": "tokenIn", "type": "address"},
            {"internalType": "uint256", "name": "amountIn", "type": "uint256"},
            {"internalType": "address", "name": "recipient", "type": "address"},
            {"internalType": "contract IERC20", "name": "tokenOut", "type": "address"},
            {"internalType": "uint256", "name": "amountOutMin", "type": "uint256"},
            {"internalType": "address", "name": "executor", "type": "address"},
            {"internalType": "bytes", "name": "executorData", "type": "bytes"},
        ],
        "name": "snwap",
        "outputs": [{"internalType": "uint256", "name": "amountOut", "type": "uint256"}],
        "stateMutability": "payable",
        "type": "function",
    }
    contract = Web3().eth.contract(abi=[snwap_abi])
    try:
        fn, params = contract.decode_function_input(hex_to_bytes(raw_data))
        return {
            "function": fn.fn_name,
            "executor": Web3.to_checksum_address(params["executor"]),
            "executorData": params["executorData"].hex() if params["executorData"] else "0x",
            "amountIn": int(params["amountIn"]),
            "amountOutMin": int(params["amountOutMin"]),
        }
    except Exception as exc:  # pragma: no cover - best effort decode
        raise ValueError(f"Failed to decode snwap payload: {exc}") from exc


def request_swap_route(
    *,
    config: RelayerConfig,
    token_in: str,
    token_out: str,
    amount_in_wei: int,
    sender: str,
    recipient: Optional[str] = None,
    web3_factory: Optional[Callable[[str], Web3]] = None,
) -> SushiQuoteResult:
    """Request a Sushi route and decode the executor payload."""
    params = {
        "tokenIn": Web3.to_checksum_address(token_in),
        "tokenOut": Web3.to_checksum_address(token_out),
        "amount": str(amount_in_wei),
        "maxSlippage": str(config.defaults.max_slippage),
        "sender": Web3.to_checksum_address(sender),
        "recipient": Web3.to_checksum_address(recipient) if recipient else Web3.to_checksum_address(sender),
    }

    try:
        response = requests.get(
            config.api_urls.sushi_swap_base,
            params=params,
            timeout=config.defaults.api_timeout,
        )
        response.raise_for_status()
    except requests.RequestException as exc:
        raise ConnectionError(f"Failed to fetch Sushi route from {config.api_urls.sushi_swap_base}: {exc}") from exc

    payload = response.json()
    if payload.get("status") != "Success":
        raise ValueError(f"Sushi API returned non-success status: {payload.get('status')}")

    tx_data = payload.get("tx", {}).get("data")
    if not tx_data:
        raise ValueError("Sushi API response missing transaction payload")

    try:
        multi = _decode_snwap_multiple(tx_data)
        executor = multi["executors"][0]
        executor_address = Web3.to_checksum_address(executor["executor"])
        executor_data = executor["data"]
    except Exception:
        # Fall back to a single swap decode when multiple execution routing failed.
        single = _decode_snwap(tx_data)
        executor_address = single["executor"]
        executor_data = single["executorData"]

    rpc_url = config.base_chain.ensure_rpc_url()
    web3 = web3_factory(rpc_url) if web3_factory else Web3(Web3.HTTPProvider(rpc_url))
    ensure_web3_connected(web3, expected_chain_id=config.base_chain.chain_id)

    return SushiQuoteResult(
        executor=executor_address,
        executor_data=hex_to_bytes(executor_data),
        chain_id=config.base_chain.chain_id,
        recipient=params["recipient"],
        amount_in=int(payload["amountIn"]),
        assumed_amount_out=int(payload["assumedAmountOut"]),
        block_number=web3.eth.block_number,
    )


def _load_lifi_abi() -> Optional[list]:
    try:
        return load_contract_abi("lifi.json")
    except FileNotFoundError:
        return None


def get_jumper_transaction(
    *,
    config: RelayerConfig,
    amount: int,
    from_address: str,
    to_address: str,
    web3_factory: Optional[Callable[[str], Web3]] = None,
) -> Dict[str, Any]:
    """Fetch and decode a Jumper (Li.Fi) transaction request."""
    params = {
        "fromChain": config.base_chain.chain_id,
        "toChain": config.ethereum_chain.chain_id,
        "fromToken": config.base_contracts.usdc_address,
        "toToken": config.ethereum_contracts.usdc_address,
        "fromAmount": str(amount),
        "fromAddress": Web3.to_checksum_address(from_address),
        "toAddress": Web3.to_checksum_address(to_address),
    }
    try:
        response = requests.get(
            config.api_urls.lifi_quote,
            params=params,
            timeout=config.defaults.api_timeout,
        )
        response.raise_for_status()
    except requests.RequestException as exc:
        raise ConnectionError(f"Failed to fetch Li.Fi quote from {config.api_urls.lifi_quote}: {exc}") from exc

    data = response.json()
    tx_data = data["transactionRequest"]

    rpc_url = config.base_chain.ensure_rpc_url()
    web3 = web3_factory(rpc_url) if web3_factory else Web3(Web3.HTTPProvider(rpc_url))
    ensure_web3_connected(web3, expected_chain_id=config.base_chain.chain_id)

    decoded = _decode_transaction_call(
        web3=web3,
        lifi_diamond_address=config.base_contracts.lifi_diamond_address,
        tx_data=tx_data,
    )

    return {"quote": data, "transaction": tx_data, "decoded": decoded}


def _decode_transaction_call(*, web3: Web3, lifi_diamond_address: str, tx_data: Dict[str, Any]) -> Dict[str, Any]:
    """Decode the transaction payload when the call targets LiFiDiamond."""
    target = Web3.to_checksum_address(tx_data["to"])
    result: Dict[str, Any] = {"to": target, "selector": tx_data["data"][:10], "decoded": None}

    if target.lower() != lifi_diamond_address.lower():
        result["note"] = "Not a LiFiDiamond call"
        return result

    abi = _load_lifi_abi()
    if not abi:
        result["note"] = "LiFi ABI not found"
        return result

    contract = web3.eth.contract(address=lifi_diamond_address, abi=abi)
    try:
        function, decoded_inputs = contract.decode_function_input(tx_data["data"])
        result["decoded"] = {"function": function.fn_name, "inputs": decoded_inputs}
    except Exception as exc:  # pragma: no cover - defensive logging branch
        result["note"] = f"Failed to decode payload: {exc}"

    return result


__all__ = ["get_jumper_transaction", "request_swap_route"]
