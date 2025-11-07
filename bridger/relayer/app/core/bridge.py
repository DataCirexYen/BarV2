"""Bridge parameter construction."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, ROUND_DOWN
from typing import Callable, Dict

from web3 import Web3

from relayer.config import RelayerConfig
from relayer.core import quotes
from relayer.core.tokens import balance_of
from relayer.core.utils import ensure_web3_connected, get_logger, hex_to_bytes

LOGGER = get_logger("relayer.bridge")


@dataclass(frozen=True)
class BridgeBuildResult:
    """Prepared call data for invoking the bridge leg."""

    call_target: str
    call_data: bytes
    native_value: int
    bridge_amount: int
    contract_usdc_balance: int
    min_total_usdc: int
    jumper_payload: Dict[str, object]


def build_bridge_call(
    *,
    config: RelayerConfig,
    web3: Web3,
    contract_address: str,
    min_total_usdc: int,
    jumper_fn: Callable[..., Dict[str, object]] = quotes.get_jumper_transaction,
) -> BridgeBuildResult:

    ensure_web3_connected(web3, expected_chain_id=config.base_chain.chain_id)

    contract_balance = balance_of(web3, config.base_contracts.usdc_address, contract_address)
    bridge_amount = contract_balance + min_total_usdc

    jumper_details = jumper_fn(
        config=config,
        amount=bridge_amount,
        from_address=contract_address,
        to_address=config.addresses.mainnet_recipient,
    )

    tx = jumper_details["transaction"]
    call_target = Web3.to_checksum_address(tx["to"])
    call_data = hex_to_bytes(tx["data"])
    native_value = int(tx["value"], 16)

    LOGGER.info(
        "Prepared bridge call target=%s amount=%s contract_balance=%s min_total_usdc=%s",
        call_target,
        bridge_amount,
        contract_balance,
        min_total_usdc,
    )

    return BridgeBuildResult(
        call_target=call_target,
        call_data=call_data,
        native_value=native_value,
        bridge_amount=bridge_amount,
        contract_usdc_balance=contract_balance,
        min_total_usdc=min_total_usdc,
        jumper_payload=jumper_details,
    )


__all__ = ["BridgeBuildResult", "build_bridge_call"]
