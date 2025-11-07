#!/usr/bin/env python3
"""Debug script to inspect swap-and-bridge parameters using the refactored relayer."""

import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from eth_account import Account
from web3 import Web3

PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from relayer.config import load_config
from relayer.core.bridge import build_bridge_call
from relayer.core.swap import build_swap_parameters
from relayer.core.validation import validate_bridge_call, validate_swap_inputs

load_dotenv()


def _ensure_web3(url: str) -> Web3:
    web3 = Web3(Web3.HTTPProvider(url))
    if not web3.is_connected():
        raise ConnectionError(f"Failed to connect to RPC: {url}")
    return web3


def main() -> None:
    """Debug the parameters being generated."""
    config = load_config()
    rpc_url = os.getenv("RPC_URL", config.base_chain.ensure_rpc_url())
    private_key = os.getenv("PRIVATE_KEY")

    if private_key:
        account = Account.from_key(private_key)
        signer_address = account.address
    else:
        signer_address = "0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59"
        print("⚠️  PRIVATE_KEY not set, using fallback signer address for read-only checks")

    web3 = _ensure_web3(rpc_url)
    print(f"🔍 Using signer address: {signer_address}\n")

    try:
        swap_result = build_swap_parameters(
            config=config,
            web3=web3,
            chwomper_address=config.base_contracts.chwmper_address,
            contract_address=config.base_contracts.revenue_bridger_address,
        )

        bridge_result = build_bridge_call(
            config=config,
            web3=web3,
            contract_address=config.base_contracts.revenue_bridger_address,
            assumed_new_usdc=swap_result.assumed_total_usdc,
        )

        token_checks = validate_swap_inputs(
            config=config,
            web3=web3,
            input_tokens=swap_result.input_tokens,
            output_tokens=swap_result.output_tokens,
            executors=swap_result.executors,
        )

        native_balance = web3.eth.get_balance(Web3.to_checksum_address(signer_address))
        bridge_checks = validate_bridge_call(
            config=config,
            call_target=bridge_result.call_target,
            native_balance=native_balance,
            native_value=bridge_result.native_value,
        )

        print("✅ Parameters fetched successfully!\n")
        print("=" * 60)
        print("PARAMETERS")
        print("=" * 60)
        print(f"\n📥 Input Tokens: {swap_result.input_tokens}")
        print(f"📤 Output Tokens: {swap_result.output_tokens}")
        print(f"⚙️  Executors: {[(executor, value, len(data)) for executor, value, data in swap_result.executors]}")
        print(f"🎯 Min USDC Out: {swap_result.min_total_usdc} ({swap_result.min_total_usdc / 10**6:.6f} USDC)")
        print(f"💡 Assumed USDC Out: {swap_result.assumed_total_usdc} ({swap_result.assumed_total_usdc / 10**6:.6f} USDC)")
        print(f"🎯 Call Target: {bridge_result.call_target}")
        print(f"🧮 Call Data Length: {len(bridge_result.call_data)} bytes")
        print(f"⛽ Native Value: {bridge_result.native_value} ({bridge_result.native_value / 10**18:.6f} ETH)")

        if swap_result.executors:
            first_executor_data = swap_result.executors[0][2]
            print("\n⚙️  Executor Data (first 100 chars):")
            print(f"   0x{first_executor_data.hex()[:100]}...")
        print("\n📞 Call Data (first 100 chars):")
        print(f"   0x{bridge_result.call_data.hex()[:100]}...")

        token_allowances = [
            (check.symbol, check.balance, check.allowance, check.required_amount) for check in token_checks
        ]
        print("\n🔐 Token Allowance Checks:")
        for symbol, balance, allowance, required in token_allowances:
            status = "OK" if allowance >= required else "INSUFFICIENT"
            print(
                f"   {symbol}: balance={balance} allowance={allowance} required={required} -> {status}"
            )

        chwmper_weth = web3.eth.contract(
            address=config.base_contracts.whitelisted_tokens[0].address,
            abi=[{"constant": True, "inputs": [{"name": "_owner", "type": "address"}], "name": "balanceOf", "outputs": [{"name": "balance", "type": "uint256"}], "type": "function"}],
        )
        chwmper_balance = chwmper_weth.functions.balanceOf(config.base_contracts.chwmper_address).call()
        print(f"\n💰 CHWMPER {config.base_contracts.whitelisted_tokens[0].symbol} Balance: {chwmper_balance}")
        print(f"💰 Signer Native Balance: {native_balance} ({native_balance / 10**18:.6f} ETH)")
        if not bridge_checks.has_sufficient_native:
            print("⚠️  Signer native balance may be insufficient for gas + call value.")

        print("\n✅ Parameter inspection complete.")
    except Exception as exc:  # pragma: no cover - debugging script
        print(f"\n❌ Error fetching parameters: {exc}")
        import traceback

        traceback.print_exc()


if __name__ == "__main__":
    main()
