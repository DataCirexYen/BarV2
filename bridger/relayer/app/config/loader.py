"""Config loader for the relayer project."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, MutableMapping, Optional

from web3 import Web3


class ConfigError(ValueError):
    """Raised when configuration data is invalid or missing."""


def _require_keys(data: Mapping[str, Any], keys: Iterable[str], context: str) -> None:
    missing = [key for key in keys if key not in data]
    if missing:
        raise ConfigError(f"{context} missing required keys: {', '.join(missing)}")


def _to_checksum(value: str, *, field_name: str) -> str:
    try:
        return Web3.to_checksum_address(value)
    except Exception as exc:  # web3 raises ValueError for malformed inputs
        raise ConfigError(f"Invalid address for {field_name}: {value}") from exc


@dataclass(frozen=True)
class ChainConfig:
    """Configuration for a blockchain network."""

    chain_id: int
    rpc_url: Optional[str] = None

    def ensure_rpc_url(self) -> str:
        """Return the RPC URL or raise if it is missing."""
        if not self.rpc_url:
            raise ConfigError("RPC URL required but not configured")
        return self.rpc_url


@dataclass(frozen=True)
class TokenConfig:
    """Whitelisted token details."""

    symbol: str
    address: str


@dataclass(frozen=True)
class BaseContracts:
    """Contract addresses for Base network deployment."""

    chwmper_address: str
    revenue_bridger_address: str
    redsnwapper_address: str
    lifi_diamond_address: str
    usdc_address: str
    whitelisted_tokens: List[TokenConfig]


@dataclass(frozen=True)
class EthereumContracts:
    """Contract addresses for Ethereum mainnet deployment."""

    usdc_address: str


@dataclass(frozen=True)
class DefaultsConfig:
    """Default operational parameters."""

    bridge_usdc_amount: float
    usdc_threshold: int
    max_slippage: float
    slippage_tolerance: float
    api_timeout: int


@dataclass(frozen=True)
class ApiUrlsConfig:
    """API endpoints required for quoting logic."""

    sushi_swap_base: str
    lifi_quote: str


@dataclass(frozen=True)
class AddressesConfig:
    """Additional addresses used by the relayer."""

    mainnet_recipient: str


@dataclass(frozen=True)
class RelayerConfig:
    """Typed wrapper around the relayer configuration."""

    base_chain: ChainConfig
    ethereum_chain: ChainConfig
    base_contracts: BaseContracts
    ethereum_contracts: EthereumContracts
    defaults: DefaultsConfig
    api_urls: ApiUrlsConfig
    addresses: AddressesConfig
    raw: Mapping[str, Any] = field(repr=False)

    def to_dict(self) -> Dict[str, Any]:
        """Return the original configuration mapping."""
        return dict(self.raw)


def _normalize_tokens(tokens: Any) -> List[TokenConfig]:
    if isinstance(tokens, Mapping):
        items = list(tokens.items())
    elif isinstance(tokens, Iterable):
        items = [(str(idx), value) for idx, value in enumerate(tokens)]
    else:
        raise ConfigError("whitelisted_tokens must be a mapping or iterable of addresses")

    result: List[TokenConfig] = []
    for symbol, address in items:
        checksum_address = _to_checksum(address, field_name=f"whitelisted token {symbol}")
        result.append(TokenConfig(symbol=symbol, address=checksum_address))
    if not result:
        raise ConfigError("whitelisted_tokens cannot be empty")
    return result


def _load_json(path: Path) -> MutableMapping[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError as exc:
        raise ConfigError(f"Config file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(f"Config file contains invalid JSON: {path}") from exc


def load_config(config_path: Optional[Path] = None) -> RelayerConfig:
    """Load and validate relayer configuration data."""
    config_path = config_path or Path("config.json")
    data = _load_json(config_path)

    _require_keys(data, ["contracts", "addresses", "chains", "defaults", "api_urls"], "config")

    contracts = data["contracts"]
    addresses = data["addresses"]
    chains = data["chains"]
    defaults = data["defaults"]
    api_urls = data["api_urls"]

    _require_keys(contracts, ["base", "ethereum"], "contracts")
    _require_keys(chains, ["base", "ethereum"], "chains")

    base_contracts_data = contracts["base"]
    _require_keys(
        base_contracts_data,
        [
            "chwmper_address",
            "revenue_bridger_address",
            "redsnwapper_address",
            "lifi_diamond_address",
            "usdc_address",
            "whitelisted_tokens",
        ],
        "base contracts",
    )
    base_contracts = BaseContracts(
        chwmper_address=_to_checksum(base_contracts_data["chwmper_address"], field_name="chwmper_address"),
        revenue_bridger_address=_to_checksum(base_contracts_data["revenue_bridger_address"], field_name="revenue_bridger_address"),
        redsnwapper_address=_to_checksum(base_contracts_data["redsnwapper_address"], field_name="redsnwapper_address"),
        lifi_diamond_address=_to_checksum(base_contracts_data["lifi_diamond_address"], field_name="lifi_diamond_address"),
        usdc_address=_to_checksum(base_contracts_data["usdc_address"], field_name="base usdc_address"),
        whitelisted_tokens=_normalize_tokens(base_contracts_data["whitelisted_tokens"]),
    )

    ethereum_contracts_data = contracts["ethereum"]
    _require_keys(ethereum_contracts_data, ["usdc_address"], "ethereum contracts")
    eth_contracts = EthereumContracts(
        usdc_address=_to_checksum(ethereum_contracts_data["usdc_address"], field_name="ethereum usdc_address")
    )

    base_chain_data = chains["base"]
    _require_keys(base_chain_data, ["chain_id", "rpc_url"], "base chain")
    base_chain = ChainConfig(chain_id=int(base_chain_data["chain_id"]), rpc_url=str(base_chain_data["rpc_url"]))

    ethereum_chain_data = chains["ethereum"]
    _require_keys(ethereum_chain_data, ["chain_id"], "ethereum chain")
    eth_chain = ChainConfig(chain_id=int(ethereum_chain_data["chain_id"]), rpc_url=ethereum_chain_data.get("rpc_url"))

    _require_keys(addresses, ["mainnet_recipient"], "addresses")
    addresses_config = AddressesConfig(
        mainnet_recipient=_to_checksum(addresses["mainnet_recipient"], field_name="mainnet_recipient")
    )

    _require_keys(
        defaults,
        ["bridge_usdc_amount", "usdc_threshold", "max_slippage", "slippage_tolerance", "api_timeout"],
        "defaults",
    )
    defaults_config = DefaultsConfig(
        bridge_usdc_amount=float(defaults["bridge_usdc_amount"]),
        usdc_threshold=int(defaults["usdc_threshold"]),
        max_slippage=float(defaults["max_slippage"]),
        slippage_tolerance=float(defaults["slippage_tolerance"]),
        api_timeout=int(defaults["api_timeout"]),
    )
    if defaults_config.usdc_threshold <= 0:
        raise ConfigError("defaults.usdc_threshold must be positive")
    if defaults_config.max_slippage <= 0 or defaults_config.max_slippage >= 1:
        raise ConfigError("defaults.max_slippage must be between 0 and 1")
    if defaults_config.slippage_tolerance <= 0 or defaults_config.slippage_tolerance > 1:
        raise ConfigError("defaults.slippage_tolerance must be between 0 and 1 (exclusive)")
    if defaults_config.api_timeout <= 0:
        raise ConfigError("defaults.api_timeout must be positive")

    _require_keys(api_urls, ["sushi_swap_base", "lifi_quote"], "api_urls")
    api_config = ApiUrlsConfig(
        sushi_swap_base=str(api_urls["sushi_swap_base"]),
        lifi_quote=str(api_urls["lifi_quote"]),
    )

    return RelayerConfig(
        base_chain=base_chain,
        ethereum_chain=eth_chain,
        base_contracts=base_contracts,
        ethereum_contracts=eth_contracts,
        defaults=defaults_config,
        api_urls=api_config,
        addresses=addresses_config,
        raw=data,
    )


__all__ = [
    "ApiUrlsConfig",
    "AddressesConfig",
    "BaseContracts",
    "ChainConfig",
    "ConfigError",
    "DefaultsConfig",
    "EthereumContracts",
    "RelayerConfig",
    "TokenConfig",
    "load_config",
]
