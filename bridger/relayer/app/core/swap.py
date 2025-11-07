"""Swap parameter construction logic."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, ROUND_DOWN
from typing import Callable, List, Sequence

from web3 import Web3

from relayer.config import RelayerConfig, TokenConfig
from relayer.core import quotes
from relayer.core.tokens import balance_of
from relayer.core.utils import SushiQuoteResult, ensure_web3_connected, get_logger

LOGGER = get_logger("relayer.swap")


@dataclass(frozen=True)
class SwapTokenQuote:
    """Details collected while preparing swap input tokens."""

    symbol: str
    token_address: str
    balance: int
    assumed_usdc_out: int
    min_usdc_out: int
    executor: str
    executor_data: bytes


@dataclass(frozen=True)
class SwapBuildResult:
    """Finalised swap parameters ready for ``swapAndBridge``."""

    input_tokens: List[tuple]
    output_tokens: List[tuple]
    executors: List[tuple]
    min_total_usdc: int
    assumed_total_usdc: int
    token_quotes: Sequence[SwapTokenQuote]


def _iter_whitelisted_tokens(tokens: Sequence[TokenConfig]) -> Sequence[TokenConfig]:
    return sorted(tokens, key=lambda token: token.symbol)


def build_swap_parameters(
    *,
    config: RelayerConfig,
    web3: Web3,
    chwomper_address: str,
    contract_address: str,
    quote_fn: Callable[..., SushiQuoteResult] = quotes.request_swap_route,
) -> SwapBuildResult:

    ensure_web3_connected(web3, expected_chain_id=config.base_chain.chain_id)

    tokens = list(_iter_whitelisted_tokens(config.base_contracts.whitelisted_tokens))
    if not tokens:
        raise ValueError("No whitelisted tokens configured")

    input_tokens: List[tuple] = []
    executors: List[tuple] = []
    quotes_collected: List[SwapTokenQuote] = []

    slippage_multiplier = Decimal(str(config.defaults.slippage_tolerance))
    total_assumed = 0
    total_min = 0

    for token in tokens:
        balance = balance_of(web3, token.address, chwomper_address)
        if balance == 0:
            LOGGER.info("Skip %s (%s): CHWMPER balance is zero", token.symbol, token.address)
            continue

        try:
            sushi_quote = quote_fn(
                config=config,
                token_in=token.address,
                token_out=config.base_contracts.usdc_address,
                amount_in_wei=balance,
                sender=contract_address,
                recipient=contract_address,
            )
        except Exception as exc:
            LOGGER.warning("Failed to fetch Sushi quote for %s (%s): %s", token.symbol, token.address, exc)
            continue

        if sushi_quote.assumed_amount_out < config.defaults.usdc_threshold:
            LOGGER.info(
                "Skip %s (%s): quote %s below USDC threshold %s",
                token.symbol,
                token.address,
                sushi_quote.assumed_amount_out,
                config.defaults.usdc_threshold,
            )
            continue

        min_out = int(
            (Decimal(sushi_quote.assumed_amount_out) * slippage_multiplier).quantize(
                Decimal("1"), rounding=ROUND_DOWN
            )
        )

        input_tokens.append((token.address, balance, sushi_quote.executor))
        executors.append((sushi_quote.executor, 0, sushi_quote.executor_data))
        total_assumed += sushi_quote.assumed_amount_out
        total_min += min_out

        quotes_collected.append(
            SwapTokenQuote(
                symbol=token.symbol,
                token_address=token.address,
                balance=balance,
                assumed_usdc_out=sushi_quote.assumed_amount_out,
                min_usdc_out=min_out,
                executor=sushi_quote.executor,
                executor_data=sushi_quote.executor_data,
            )
        )

    if not input_tokens:
        raise ValueError("No eligible tokens to swap after applying thresholds")

    output_tokens = [(config.base_contracts.usdc_address, contract_address, total_min)]

    return SwapBuildResult(
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        executors=executors,
        min_total_usdc=total_min,
        assumed_total_usdc=total_assumed,
        token_quotes=quotes_collected,
    )


__all__ = ["SwapBuildResult", "SwapTokenQuote", "build_swap_parameters"]
