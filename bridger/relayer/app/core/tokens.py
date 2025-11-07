"""Token balance and allowance helpers."""

from __future__ import annotations

from typing import Dict, Tuple

from web3 import Web3
from web3.contract import Contract

from relayer.core.utils import ensure_web3_connected

ERC20_ABI = [
    {
        "constant": True,
        "inputs": [{"name": "_owner", "type": "address"}],
        "name": "balanceOf",
        "outputs": [{"name": "balance", "type": "uint256"}],
        "type": "function",
    },
    {
        "constant": True,
        "inputs": [{"name": "_owner", "type": "address"}, {"name": "_spender", "type": "address"}],
        "name": "allowance",
        "outputs": [{"name": "", "type": "uint256"}],
        "type": "function",
    },
]


def get_contract(web3: Web3, token_address: str) -> Contract:
    """Return a cached ERC20 contract instance for ``token_address``."""
    ensure_web3_connected(web3)
    return _get_or_create_contract(web3, token_address)


_CONTRACT_CACHE: Dict[Tuple[int, str], Contract] = {}


def _get_or_create_contract(web3: Web3, token_address: str) -> Contract:
    checksum_address = Web3.to_checksum_address(token_address)
    key = (id(web3), checksum_address)
    contract = _CONTRACT_CACHE.get(key)
    if contract is None:
        contract = web3.eth.contract(address=checksum_address, abi=ERC20_ABI)
        _CONTRACT_CACHE[key] = contract
    return contract


def balance_of(web3: Web3, token_address: str, owner: str) -> int:
    """Fetch the ERC20 balance."""
    contract = get_contract(web3, token_address)
    return contract.functions.balanceOf(Web3.to_checksum_address(owner)).call()


def allowance_of(web3: Web3, token_address: str, owner: str, spender: str) -> int:
    """Fetch the ERC20 allowance."""
    contract = get_contract(web3, token_address)
    return contract.functions.allowance(
        Web3.to_checksum_address(owner),
        Web3.to_checksum_address(spender),
    ).call()


def snapshot_balances(web3: Web3, token_addresses: Dict[str, str], owner: str) -> Dict[str, int]:
    """Return balances for token symbols keyed by symbol."""
    return {symbol: balance_of(web3, address, owner) for symbol, address in token_addresses.items()}


__all__ = ["ERC20_ABI", "allowance_of", "balance_of", "get_contract", "snapshot_balances"]
