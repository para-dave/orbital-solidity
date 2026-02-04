# Orbital AMM - Quick Start Guide

Get the Orbital AMM running on Tempo testnet in minutes.

## Prerequisites

- Git
- Node.js v16+ (optional, for frontend later)
- Foundry (for Solidity development)

## Step 1: Install Foundry

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash

# Update Foundry
foundryup

# Verify installation
forge --version
cast --version
```

## Step 2: Install Dependencies

```bash
cd bullseye

# Install Forge dependencies
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts

# Verify installation
forge build
```

Expected output: `Compiler run successful!`

## Step 3: Run Tests

```bash
# Run all tests with verbosity
forge test -vv

# Run specific test suite
forge test --match-path test/FixedPointMath.t.sol -vvv

# Run with gas reports
forge test --gas-report
```

Expected: All tests should pass ✅

## Step 4: Set Up Tempo Testnet

### Get Tempo RPC Access

1. Visit [tempo.xyz](https://tempo.xyz/)
2. Get testnet RPC URL (check docs or Discord)
3. Note the chain ID

### Get Testnet Tokens

1. Visit faucet: https://faucets.chain.link/tempo-testnet
2. Enter your wallet address
3. Request testnet tokens (for gas)

### Configure Environment

```bash
# Copy example env file
cp .env.example .env

# Edit .env with your values
nano .env
```

Update with:
```
TEMPO_RPC_URL=https://actual-tempo-rpc-url.com
TEMPO_CHAIN_ID=<actual_chain_id>
PRIVATE_KEY=<your_private_key>
```

**⚠️ NEVER commit your actual private key!**

## Step 5: Deploy to Tempo Testnet

### Dry Run (Simulation)

```bash
# Simulate deployment without broadcasting
forge script script/DeployOrbital.s.sol \
    --rpc-url $TEMPO_RPC_URL
```

### Actual Deployment

```bash
# Load environment variables
source .env

# Deploy to Tempo testnet
forge script script/DeployOrbital.s.sol \
    --rpc-url $TEMPO_RPC_URL \
    --broadcast \
    --private-key $PRIVATE_KEY
```

Expected output:
```
Deploying from: 0x...
Deployed USDC at: 0x...
Deployed USDT at: 0x...
Deployed DAI at: 0x...
Deployed OrbitalPool at: 0x...
Created tick ID: 0
Added initial liquidity, received shares: ...
Deployment complete!
```

Deployment addresses are saved to `deployment.json`.

## Step 6: Verify Deployment

```bash
# Load deployment addresses
POOL_ADDRESS=$(jq -r .pool deployment.json)
USDC_ADDRESS=$(jq -r .usdc deployment.json)

# Check pool info
cast call $POOL_ADDRESS "nTokens()" --rpc-url $TEMPO_RPC_URL
cast call $POOL_ADDRESS "feesBps()" --rpc-url $TEMPO_RPC_URL
cast call $POOL_ADDRESS "getTickCount()" --rpc-url $TEMPO_RPC_URL

# Check reserves
cast call $POOL_ADDRESS "totalReserves(uint256)(uint256)" 0 --rpc-url $TEMPO_RPC_URL
cast call $POOL_ADDRESS "totalReserves(uint256)(uint256)" 1 --rpc-url $TEMPO_RPC_URL
cast call $POOL_ADDRESS "totalReserves(uint256)(uint256)" 2 --rpc-url $TEMPO_RPC_URL

# Check price (USDT/USDC)
cast call $POOL_ADDRESS "getPrice(uint256,uint256)(uint256)" 0 1 --rpc-url $TEMPO_RPC_URL
```

## Step 7: Test a Swap

### Approve Tokens

```bash
# Approve USDC for pool
cast send $USDC_ADDRESS \
    "approve(address,uint256)" \
    $POOL_ADDRESS \
    1000000000000000000000 \
    --rpc-url $TEMPO_RPC_URL \
    --private-key $PRIVATE_KEY
```

### Execute Swap

```bash
# Swap 100 USDC for USDT
# tokenInIdx=0 (USDC)
# amountIn=100e18
# tokenOutIdx=1 (USDT)
# minAmountOut=90e18 (10% slippage tolerance)

cast send $POOL_ADDRESS \
    "swap(uint256,uint256,uint256,uint256)" \
    0 \
    100000000000000000000 \
    1 \
    90000000000000000000 \
    --rpc-url $TEMPO_RPC_URL \
    --private-key $PRIVATE_KEY
```

### Check Price Changed

```bash
# Check new price after swap
cast call $POOL_ADDRESS "getPrice(uint256,uint256)(uint256)" 0 1 --rpc-url $TEMPO_RPC_URL
```

Price should have changed!

## Step 8: Add More Liquidity (Optional)

```bash
# Approve all tokens
cast send $USDC_ADDRESS "approve(address,uint256)" $POOL_ADDRESS 10000000000000000000000 --rpc-url $TEMPO_RPC_URL --private-key $PRIVATE_KEY
cast send $USDT_ADDRESS "approve(address,uint256)" $POOL_ADDRESS 10000000000000000000000 --rpc-url $TEMPO_RPC_URL --private-key $PRIVATE_KEY
cast send $DAI_ADDRESS "approve(address,uint256)" $POOL_ADDRESS 10000000000000000000000 --rpc-url $TEMPO_RPC_URL --private-key $PRIVATE_KEY

# Add liquidity to tick 0
# Pass array of amounts [1000e18, 1000e18, 1000e18]
cast send $POOL_ADDRESS \
    "addLiquidity(uint256,uint256[])" \
    0 \
    "[1000000000000000000000,1000000000000000000000,1000000000000000000000]" \
    --rpc-url $TEMPO_RPC_URL \
    --private-key $PRIVATE_KEY
```

## Troubleshooting

### Foundry Not Found
```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Tests Fail
```bash
# Clean and rebuild
forge clean
forge build
forge test -vvv  # Triple verbosity for debugging
```

### Deployment Fails
- Check you have testnet tokens for gas
- Verify RPC URL is correct
- Ensure private key has proper format (no 0x prefix in .env)
- Check Tempo testnet status

### Transaction Reverts
- Increase gas limit: `--gas-limit 5000000`
- Check token approvals
- Verify amounts are in wei (multiply by 10^18)

### "Insufficient Liquidity"
- Pool needs liquidity before swaps
- Run deployment script which adds initial liquidity
- Or manually add liquidity with `addLiquidity`

### "Slippage Exceeded"
- Increase `minAmountOut` tolerance
- Or split large trades into smaller swaps

## Next Steps

### Monitor Your Pool
```bash
# Watch reserves change
watch "cast call $POOL_ADDRESS 'totalReserves(uint256)(uint256)' 0 --rpc-url $TEMPO_RPC_URL"

# Check sphere invariant
cast call $POOL_ADDRESS "checkInvariant(uint256)(bool)" 0 --rpc-url $TEMPO_RPC_URL
```

### Integration Testing
Run through the test scenarios:
1. Multiple LPs adding liquidity
2. Various swap sizes
3. Price impact measurement
4. Invariant verification

### Build a Frontend (Future)
- Web interface to interact with pool
- Display prices and reserves
- Execute swaps through UI
- View transaction history

### Advanced Features
- Deploy multiple pools
- Create router for multi-hop swaps
- Add fee collection for LPs
- Implement remove liquidity

## Useful Commands

```bash
# Format code
forge fmt

# Check coverage
forge coverage

# Create snapshot (gas baseline)
forge snapshot

# Decode transaction
cast tx <TX_HASH> --rpc-url $TEMPO_RPC_URL

# Get transaction receipt
cast receipt <TX_HASH> --rpc-url $TEMPO_RPC_URL

# Check balance
cast balance <ADDRESS> --rpc-url $TEMPO_RPC_URL

# Estimate gas
cast estimate <TO> <SIG> <ARGS> --rpc-url $TEMPO_RPC_URL
```

## Resources

- **Foundry Book**: https://book.getfoundry.sh/
- **Tempo Docs**: https://tempo.xyz/ (check for latest docs)
- **Implementation Guide**: See `SOLIDITY_IMPLEMENTATION.md`
- **Python Reference**: `orbital_simple.py`, `fixed_point.py`

## Support

Issues or questions?
1. Check `SOLIDITY_IMPLEMENTATION.md` for detailed docs
2. Review test files for usage examples
3. Compare with Python reference implementation
4. Check Tempo Discord/docs for network-specific help

## Success Criteria

After following this guide, you should have:
- ✅ Orbital AMM deployed on Tempo testnet
- ✅ Initial liquidity added
- ✅ Test swap executed successfully
- ✅ Sphere invariant verified
- ✅ Deployment addresses saved
- ✅ Gas costs measured

**Congratulations! Your Orbital AMM is live on Tempo! 🎉**
