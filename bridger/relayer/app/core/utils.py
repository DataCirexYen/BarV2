"""Utility helpers shared across relayer core modules."""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from decimal import Decimal, ROUND_DOWN
from pathlib import Path
from typing import Any, Dict, Iterable, Optional

from web3 import Web3


def get_logger(name: str = "relayer") -> logging.Logger:
    """Return a configured logger that prints to stdout."""
    logger = logging.getLogger(name)
    if not logger.handlers:
        handler = logging.StreamHandler()
        formatter = logging.Formatter("%(asctime)s | %(levelname)s | %(name)s | %(message)s")
        handler.setFormatter(formatter)
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
    return logger


def load_json_file(path: Path) -> Dict[str, Any]:
    """Load JSON data from ``path``."""
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def ensure_web3_connected(web3: Web3, *, expected_chain_id: Optional[int] = None) -> None:
    """Validate that ``web3`` is connected and optionally matches the expected chain id."""
    if not web3.is_connected():
        raise ConnectionError("Failed to connect to the configured RPC endpoint")
    if expected_chain_id is not None and web3.eth.chain_id != expected_chain_id:
        raise ValueError(f"RPC chain ID mismatch: expected {expected_chain_id}, got {web3.eth.chain_id}")


def hex_to_bytes(data: str) -> bytes:
    """Convert a hex string (with or without ``0x``) to bytes."""
    data = data[2:] if data.startswith("0x") else data
    return bytes.fromhex(data)


def apply_discount(value: int, multiplier: Decimal) -> int:
    """Apply a multiplier to a value and round down to the nearest wei."""
    return int((Decimal(value) * multiplier).quantize(Decimal("1"), rounding=ROUND_DOWN))


def sum_ints(values: Iterable[int]) -> int:
    """Return the sum of an iterable of integers."""
    total = 0
    for value in values:
        total += int(value)
    return total


@dataclass(frozen=True)
class SushiQuoteResult:
    """Decoded Sushi swap route response."""

    executor: str
    executor_data: bytes
    chain_id: int
    recipient: str
    amount_in: int
    assumed_amount_out: int
    block_number: int


__all__ = [
    "SushiQuoteResult",
    "apply_discount",
    "ensure_web3_connected",
    "get_logger",
    "hex_to_bytes",
    "load_json_file",
    "sum_ints",
]
