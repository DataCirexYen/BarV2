
1. Install dependencies:
```bash
pip install -r ../requirements.txt
```

2. Set environment variables:
```bash
export RPC_URL="https://mainnet.base.org"  # or your preferred RPC endpoint
export PRIVATE_KEY="your_private_key_here"  # Private key of wallet with TRUSTER_ROLE
```

## Usage

### Dry Run (Simulation)
Simulate the transaction without broadcasting:
```bash
python execute_swap_and_bridge.py --dry-run
```

### Execute Transaction
Send the transaction to Base Mainnet:
```bash
python execute_swap_and_bridge.py --send

