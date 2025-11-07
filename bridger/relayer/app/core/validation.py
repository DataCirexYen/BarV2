"""Validation helpers for swap and bridge parameters."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, List, Sequence, Tuple

from web3 import Web3

from relayer.config import RelayerConfig
from relayer.core.tokens import allowance_of, balance_of
from relayer.core.utils import ensure_web3_connected, get_logger

LOGGER = get_logger("relayer.validation")


@dataclass(frozen=True)
class TokenValidationResult:
    """Balance and allowance context for a token input."""

    token_address: str
    symbol: str
    required_amount: int
    balance: int
    allowance: int

    @property
    def has_allowance(self) -> bool:
        return self.allowance >= self.required_amount


def _address_symbol_map(config: RelayerConfig) -> dict:
    return {token.address.lower(): token.symbol for token in config.base_contracts.whitelisted_tokens}


def validate_swap_inputs(
    *,
    config: RelayerConfig,
    web3: Web3,
    input_tokens: Sequence[Tuple[str, int, str]],
    output_tokens: Sequence[Tuple[str, str, int]],
    executors: Sequence[Tuple[str, int, bytes]],
) -> List[TokenValidationResult]:
    """Validate swap arrays and produce balance context."""
    ensure_web3_connected(web3, expected_chain_id=config.base_chain.chain_id)

    if not input_tokens:
        raise ValueError("inputTokens array is empty")
    if not output_tokens:
        raise ValueError("outputTokens array is empty")
    if not executors:
        raise ValueError("executors array is empty")

    symbol_map = _address_symbol_map(config)
    results: List[TokenValidationResult] = []

    for token_address, amount_in, _transfer_to in input_tokens:
        balance = balance_of(web3, token_address, config.base_contracts.chwmper_address)
        allowance = allowance_of(web3, token_address, config.base_contracts.chwmper_address, config.base_contracts.revenue_bridger_address)
        checksum_address = Web3.to_checksum_address(token_address)
        symbol = symbol_map.get(checksum_address.lower(), "UNKNOWN")

        if balance < amount_in:
            raise ValueError(
                f"CHWMPER balance for {symbol} ({checksum_address}) is {balance}, "
                f"but transaction requires {amount_in}"
            )

        result = TokenValidationResult(
            token_address=checksum_address,
            symbol=symbol,
            required_amount=amount_in,
            balance=balance,
            allowance=allowance,
        )

        results.append(result)

    return results


def validate_executor_payloads(executors: Iterable[Tuple[str, int, bytes]]) -> None:
    """Ensure executor payloads are structurally sound."""
    for index, (executor, value, data) in enumerate(executors, start=1):
        if not Web3.is_checksum_address(executor):
            raise ValueError(f"Executor #{index} has invalid address: {executor}")
        if value != 0:
            LOGGER.warning("Executor #%s sends unexpected native value: %s", index, value)
        if not isinstance(data, (bytes, bytearray)):
            raise TypeError(f"Executor #{index} data must be bytes-like")


@dataclass(frozen=True)
class BridgeValidationResult:
    """Outcome of bridge preflight checks."""

    call_target: str
    native_balance: int
    required_native: int
    has_sufficient_native: bool


def validate_bridge_call(
    *,
    config: RelayerConfig,
    call_target: str,
    native_balance: int,
    native_value: int,
) -> BridgeValidationResult:
    """Validate the bridge call target and native funding."""
    if Web3.to_checksum_address(call_target) == "0x0000000000000000000000000000000000000000":
        raise ValueError("callTarget is zero address")

    expected = config.base_contracts.lifi_diamond_address
    if call_target.lower() != expected.lower():
        LOGGER.warning("callTarget %s != expected LiFiDiamond %s", call_target, expected)

    # Provide a 1M gas buffer assuming 1 gwei tip; keeps alerts consistent with legacy script.
    gas_buffer = 1_000_000 * 10**9
    required_native = native_value + gas_buffer
    has_balance = native_balance >= required_native
    if not has_balance:
        LOGGER.warning(
            "Low native balance %.6f ETH, requires at least %.6f ETH",
            native_balance / 10**18,
            required_native / 10**18,
        )

    return BridgeValidationResult(
        call_target=call_target,
        native_balance=native_balance,
        required_native=required_native,
        has_sufficient_native=has_balance,
    )


__all__ = [
    "BridgeValidationResult",
    "TokenValidationResult",
    "validate_bridge_call",
    "validate_executor_payloads",
    "validate_swap_inputs",
]
