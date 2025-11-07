"""CLI entrypoint for executing swap-and-bridge operations."""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional

from eth_account import Account
from dotenv import load_dotenv
from web3 import Web3
from web3.contract import Contract
from web3.exceptions import ContractLogicError

from relayer.config import RelayerConfig, load_config
from relayer.contracts import load_contract_abi
from relayer.core.bridge import BridgeBuildResult, build_bridge_call
from relayer.core.swap import SwapBuildResult, build_swap_parameters
from relayer.core.validation import (
    BridgeValidationResult,
    TokenValidationResult,
    validate_bridge_call,
    validate_executor_payloads,
    validate_swap_inputs,
)
from relayer.core.utils import get_logger

LOGGER = get_logger("relayer.cli")

load_dotenv()


@dataclass(frozen=True)
class ExecutionPlan:
    """Full context required to execute ``swapAndBridge``."""

    swap: SwapBuildResult
    bridge: BridgeBuildResult
    token_validations: List[TokenValidationResult]
    bridge_validation: BridgeValidationResult

    @property
    def input_tokens(self):
        return self.swap.input_tokens

    @property
    def output_tokens(self):
        return self.swap.output_tokens

    @property
    def executors(self):
        return self.swap.executors

    @property
    def min_usdc_out(self) -> int:
        return self.swap.min_total_usdc

    @property
    def call_target(self) -> str:
        return self.bridge.call_target

    @property
    def call_data(self) -> bytes:
        return self.bridge.call_data

    @property
    def native_value(self) -> int:
        return self.bridge.native_value


@dataclass(frozen=True)
class GasParameters:
    """EIP-1559 gas parameters."""

    gas: int
    gas_price: int
    max_priority_fee: int
    max_fee: int
    estimated_cost: int


class RelayerExecutor:
    """High-level orchestrator for the swap-and-bridge workflow."""

    def __init__(
        self,
        *,
        rpc_url: Optional[str],
        private_key: str,
        config: Optional[RelayerConfig] = None,
        web3_factory: Callable[[str], Web3] = lambda url: Web3(Web3.HTTPProvider(url)),
    ) -> None:
        self.config = config or load_config()

        resolved_rpc = rpc_url or self.config.base_chain.ensure_rpc_url()
        self.web3 = web3_factory(resolved_rpc)

        if not self.web3.is_connected():
            raise ConnectionError(f"Failed to connect to RPC: {resolved_rpc}")
        if self.web3.eth.chain_id != self.config.base_chain.chain_id:
            raise ValueError(
                f"Wrong chain! Expected {self.config.base_chain.chain_id}, got {self.web3.eth.chain_id}"
            )

        self.account = Account.from_key(private_key)
        self.address = self.account.address
        LOGGER.info("Connected to chain %s as %s", self.web3.eth.chain_id, self.address)

        abi = load_contract_abi("revenue_bridger_abi.json")
        self.contract: Contract = self.web3.eth.contract(
            address=self.config.base_contracts.revenue_bridger_address,
            abi=abi,
        )

    def prepare_plan(self) -> ExecutionPlan:
        """Prepare swap and bridge parameters with validations."""
        swap = build_swap_parameters(
            config=self.config,
            web3=self.web3,
            chwomper_address=self.config.base_contracts.chwmper_address,
            contract_address=self.config.base_contracts.revenue_bridger_address,
        )
        validate_executor_payloads(swap.executors)

        tokens_validation = validate_swap_inputs(
            config=self.config,
            web3=self.web3,
            input_tokens=swap.input_tokens,
            output_tokens=swap.output_tokens,
            executors=swap.executors,
        )

        bridge = build_bridge_call(
            config=self.config,
            web3=self.web3,
            contract_address=self.config.base_contracts.revenue_bridger_address,
            min_total_usdc=swap.min_total_usdc,
        )

        native_balance = self.web3.eth.get_balance(self.address)
        bridge_validation = validate_bridge_call(
            config=self.config,
            call_target=bridge.call_target,
            native_balance=native_balance,
            native_value=bridge.native_value,
        )

        return ExecutionPlan(
            swap=swap,
            bridge=bridge,
            token_validations=tokens_validation,
            bridge_validation=bridge_validation,
        )

    def estimate_gas(self, plan: ExecutionPlan) -> GasParameters:
        """Estimate gas usage for the prepared plan."""
        try:
            gas_estimate = self.contract.functions.swapAndBridge(
                plan.input_tokens,
                plan.output_tokens,
                plan.executors,
                plan.min_usdc_out,
                plan.call_target,
                plan.call_data,
                plan.native_value,
            ).estimate_gas({"from": self.address, "value": plan.native_value})
        except ContractLogicError as exc:
            raise ValueError(f"Contract would revert: {exc}") from exc

        gas_price = self.web3.eth.gas_price
        max_priority_fee = getattr(self.web3.eth, "max_priority_fee", gas_price)
        max_fee = gas_price + max_priority_fee
        return GasParameters(
            gas=gas_estimate,
            gas_price=gas_price,
            max_priority_fee=max_priority_fee,
            max_fee=max_fee,
            estimated_cost=gas_estimate * gas_price,
        )

    def build_transaction(self, plan: ExecutionPlan, gas: GasParameters) -> Dict[str, int]:
        """Build the 1559 transaction payload."""
        nonce = self.web3.eth.get_transaction_count(self.address)
        tx = self.contract.functions.swapAndBridge(
            plan.input_tokens,
            plan.output_tokens,
            plan.executors,
            plan.min_usdc_out,
            plan.call_target,
            plan.call_data,
            plan.native_value,
        ).build_transaction(
            {
                "from": self.address,
                "gas": int(gas.gas * 1.1),  # add a 10% buffer
                "maxFeePerGas": gas.max_fee,
                "maxPriorityFeePerGas": gas.max_priority_fee,
                "nonce": nonce,
                "chainId": self.config.base_chain.chain_id,
                "value": plan.native_value,
            }
        )
        return tx

    def execute_dry_run(self) -> GasParameters:
        """Perform a dry-run (simulation) of the workflow."""
        plan = self.prepare_plan()
        self._log_plan(plan)
        gas = self.estimate_gas(plan)
        self._log_gas(gas)
        return gas

    def execute_send(self) -> str:
        """Execute the workflow and broadcast the transaction."""
        plan = self.prepare_plan()
        self._log_plan(plan)

        try:
            gas = self.estimate_gas(plan)
            self._log_gas(gas)
        except Exception as exc:
            LOGGER.warning("Gas estimation failed: %s", exc)
            gas = self._fallback_gas()
            self._log_gas(gas, label="Fallback")

        tx = self.build_transaction(plan, gas)
        LOGGER.info("Signing transaction")
        signed = self.account.sign_transaction(tx)

        LOGGER.info("Broadcasting transaction")
        tx_hash = self.web3.eth.send_raw_transaction(signed.raw_transaction)
        tx_hex = tx_hash.hex()
        LOGGER.info("Transaction hash: %s", tx_hex)

        LOGGER.info("Awaiting confirmation")
        receipt = self.web3.eth.wait_for_transaction_receipt(tx_hash)
        if receipt["status"] == 1:
            LOGGER.info("Transaction confirmed in block %s (gasUsed=%s)", receipt["blockNumber"], receipt["gasUsed"])
        else:
            LOGGER.error("Transaction failed! status=%s", receipt["status"])

        return tx_hex

    def _log_plan(self, plan: ExecutionPlan) -> None:
        LOGGER.info("Prepared %s input tokens", len(plan.input_tokens))
        for idx, token in enumerate(plan.swap.token_quotes, start=1):
            LOGGER.info(
                "Token %s: %s (%s) balance=%s assumedUSDC=%s minUSDC=%s executor=%s",
                idx,
                token.symbol,
                token.token_address,
                token.balance,
                token.assumed_usdc_out,
                token.min_usdc_out,
                token.executor,
            )

        LOGGER.info("Total min USDC out: %.6f", plan.min_usdc_out / 10**6)
        LOGGER.info("Bridge target: %s", plan.call_target)
        LOGGER.info(
            "Bridge amount=%s, contract USDC balance=%s, min total USDC=%s",
            plan.bridge.bridge_amount,
            plan.bridge.contract_usdc_balance,
            plan.bridge.min_total_usdc,
        )

        for validation in plan.token_validations:
            if not validation.has_allowance:
                LOGGER.warning(
                    "Allowance for %s (%s) is insufficient (allowance=%s required=%s)",
                    validation.symbol,
                    validation.token_address,
                    validation.allowance,
                    validation.required_amount,
                )

        if not plan.bridge_validation.has_sufficient_native:
            LOGGER.warning(
                "Signer native balance %.6f ETH below required %.6f ETH",
                plan.bridge_validation.native_balance / 10**18,
                plan.bridge_validation.required_native / 10**18,
            )

    @staticmethod
    def _log_gas(gas: GasParameters, *, label: str = "Estimate") -> None:
        LOGGER.info(
            "%s gas=%s maxFee=%.2f gwei priority=%.2f gwei estimatedCost=%.6f ETH",
            label,
            gas.gas,
            gas.max_fee / 10**9,
            gas.max_priority_fee / 10**9,
            gas.estimated_cost / 10**18,
        )

    def _fallback_gas(self) -> GasParameters:
        gas_price = self.web3.eth.gas_price
        max_priority_fee = getattr(self.web3.eth, "max_priority_fee", gas_price)
        return GasParameters(
            gas=1_000_000,
            gas_price=gas_price,
            max_priority_fee=max_priority_fee,
            max_fee=gas_price + max_priority_fee,
            estimated_cost=1_000_000 * gas_price,
        )


def _parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Execute swapAndBridge on RevenueBridger contract")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--dry-run", action="store_true", help="Simulate transaction without sending")
    group.add_argument("--send", action="store_true", help="Send transaction to Base Mainnet")
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> None:
    args = _parse_args(argv)

    rpc_url_env = os.getenv("RPC_URL") or ""
    rpc_url = rpc_url_env.strip() or None

    private_key_env = os.getenv("PRIVATE_KEY") or ""
    private_key = private_key_env.strip()

    if not private_key:
        print("❌ Error: PRIVATE_KEY environment variable not set")
        sys.exit(1)

    try:
        executor = RelayerExecutor(rpc_url=rpc_url, private_key=private_key)
        if args.dry_run:
            executor.execute_dry_run()
        else:
            executor.execute_send()
    except Exception as exc:
        print(f"\n❌ Error: {exc}")
        sys.exit(1)


if __name__ == "__main__":  # pragma: no cover - CLI entry
    main()
