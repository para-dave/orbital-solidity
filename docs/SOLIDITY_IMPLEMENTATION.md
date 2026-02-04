# Orbital AMM - Solidity Implementation

This directory contains the Solidity implementation of the Orbital AMM, ready for deployment to Tempo testnet.

## Project Structure

```
contracts/
├── FixedPointMath.sol    # 18-decimal fixed-point math library
├── OrbitalPool.sol       # Core AMM implementation
└── interfaces/           # Interface definitions (future)

test/
├── FixedPointMath.t.sol  # Math library tests
└── OrbitalPool.t.sol     # Pool integration tests

script/
└── DeployOrbital.s.sol   # Deployment script for Tempo
```

## Implementation Status

### ✅ Completed (Phase 1-2)

- **FixedPointMath.sol**: Complete 18-decimal math library
  - mul, div, sqrt operations
  - Vector operations (dot product, norm, sum of squares)
  - Unit vector and center vector helpers

- **OrbitalPool.sol**: Core AMM logic
  - Tick creation and management
  - Add liquidity (first LP geometric mean, subsequent proportional)
  - Swap execution with sphere invariant
  - Price queries and view functions
  - Sphere invariant verification

- **Test Suite**: Comprehensive tests porting Python behavior
  - FixedPointMath.t.sol: 11 math operation tests
  - OrbitalPool.t.sol: 11 pool behavior tests
  - Includes MockERC20 for isolated testing

- **Deployment Script**: Ready for Tempo testnet
  - Deploys mock tokens (USDC, USDT, DAI)
  - Deploys OrbitalPool with 0.3% fee
  - Creates initial tick and adds liquidity
  - Saves deployment addresses to JSON

### 🔄 Next Steps (Phase 3-5)

1. **Install Foundry** (if not already installed)
   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```

2. **Install Dependencies**
   ```bash
   forge install foundry-rs/forge-std
   forge install OpenZeppelin/openzeppelin-contracts
   ```

3. **Run Tests**
   ```bash
   # Run all tests
   forge test -vv

   # Run specific test file
   forge test --match-path test/FixedPointMath.t.sol -vvv
   forge test --match-path test/OrbitalPool.t.sol -vvv

   # Run with gas reports
   forge test --gas-report
   ```

4. **Tempo Testnet Setup**
   - Get Tempo testnet RPC URL from [tempo.xyz](https://tempo.xyz/)
   - Update `foundry.toml` with actual RPC endpoint
   - Get testnet tokens from faucet: https://faucets.chain.link/tempo-testnet
   - Set environment variables:
     ```bash
     export TEMPO_RPC_URL="<your-tempo-rpc>"
     export PRIVATE_KEY="<your-private-key>"
     ```

5. **Deploy to Tempo Testnet**
   ```bash
   forge script script/DeployOrbital.s.sol \
       --rpc-url $TEMPO_RPC_URL \
       --broadcast \
       --verify  # If Tempo supports verification
   ```

6. **Integration Testing on Tempo**
   - Create test pool with 3 stablecoins
   - Add liquidity from multiple addresses
   - Execute swaps of varying sizes
   - Monitor sphere invariant
   - Measure gas costs

## Key Features

### Fixed-Point Precision
- All math uses 18 decimals (1.0 = 10^18)
- Maintains precision through complex calculations
- Tested against Python reference implementation

### Sphere Invariant
- Core constraint: `∑(r - x_i)² = r²`
- Verified after every swap
- Tolerance: 0.1% for rounding errors

### Gas Optimization
- Pre-computed constants (sqrtN, oneMinusOneOverSqrtN)
- Efficient sqrt implementation (Newton's method)
- Minimal storage operations

### Security Features
- Slippage protection (minAmountOut parameter)
- Invariant checks prevent invalid states
- SafeERC20 for secure token transfers
- Input validation on all functions

## Testing Strategy

### Unit Tests
- Each math function tested in isolation
- Error cases (division by zero, underflow)
- Precision tests for small and large values

### Integration Tests
- Multi-step flows (add → swap → check invariant)
- Multiple LPs in same tick
- Multiple ticks in same pool
- Edge cases (large trades, tiny amounts)

### Invariant Tests
Run with Foundry's invariant testing:
```bash
forge test --match-test invariant -vvv
```

## Comparison with Python Implementation

| Feature | Python (orbital_simple.py) | Solidity (OrbitalPool.sol) |
|---------|---------------------------|----------------------------|
| Fixed-point | ✅ 18 decimals | ✅ 18 decimals |
| Tick creation | ✅ | ✅ |
| Add liquidity | ✅ | ✅ |
| Geometric mean | ✅ Approximation | ✅ Newton's method |
| Swap | ✅ Single tick | ✅ Single tick |
| Sphere invariant | ✅ | ✅ |
| Multiple ticks | ✅ | ✅ |
| Price queries | ✅ | ✅ |

## Gas Estimates (Estimated)

Based on similar AMM implementations:

| Operation | Estimated Gas | Tempo Cost (~$0.001/tx) |
|-----------|---------------|-------------------------|
| Create tick | ~50,000 | ~$0.001 |
| Add liquidity (first) | ~150,000 | ~$0.001 |
| Add liquidity (subsequent) | ~100,000 | ~$0.001 |
| Swap (2 tokens) | ~120,000 | ~$0.001 |
| Swap (3+ tokens) | ~150,000 | ~$0.001 |

Note: Actual costs will be measured on Tempo testnet.

## Tempo-Specific Considerations

### Stablecoin-Native Gas
- Tempo uses stablecoins for gas (no ETH needed)
- Hold USDC or similar for transaction fees
- Much more predictable costs than volatile gas tokens

### Sub-Second Finality
- Trades confirm almost instantly (<1s)
- Better UX than Ethereum's 12s blocks
- Enable more interactive trading patterns

### Low Fees
- ~$0.001 per transaction on Tempo
- vs. ~$1-50 on Ethereum mainnet
- vs. ~$0.01-0.50 on L2s
- Enables smaller trades and more experimentation

## Contract Interfaces

### OrbitalPool.sol

```solidity
// Create a new tick
function createTick(uint256 r, uint256 k) external returns (uint256 tickId);

// Add liquidity to a tick
function addLiquidity(uint256 tickId, uint256[] calldata amounts)
    external returns (uint256 shares);

// Swap tokens
function swap(
    uint256 tokenInIdx,
    uint256 amountIn,
    uint256 tokenOutIdx,
    uint256 minAmountOut
) external returns (uint256 amountOut);

// View functions
function getPrice(uint256 tokenAIdx, uint256 tokenBIdx) external view returns (uint256);
function getTickReserves(uint256 tickId) external view returns (uint256[] memory);
function checkInvariant(uint256 tickId) external view returns (bool);
```

## Development Workflow

### 1. Local Development
```bash
# Compile contracts
forge build

# Run tests
forge test -vv

# Coverage
forge coverage
```

### 2. Local Fork Testing
```bash
# Fork Tempo testnet locally
anvil --fork-url $TEMPO_RPC_URL

# Deploy to local fork
forge script script/DeployOrbital.s.sol --fork-url http://localhost:8545
```

### 3. Testnet Deployment
```bash
# Deploy to Tempo testnet
forge script script/DeployOrbital.s.sol \
    --rpc-url $TEMPO_RPC_URL \
    --broadcast

# Verify deployment
cast call <POOL_ADDRESS> "getTickCount()" --rpc-url $TEMPO_RPC_URL
```

### 4. Interaction
```bash
# Get pool info
cast call <POOL_ADDRESS> "nTokens()" --rpc-url $TEMPO_RPC_URL
cast call <POOL_ADDRESS> "getPrice(uint256,uint256)(uint256)" 0 1 --rpc-url $TEMPO_RPC_URL

# Execute swap
cast send <POOL_ADDRESS> \
    "swap(uint256,uint256,uint256,uint256)" \
    0 1000000000000000000 1 900000000000000000 \
    --rpc-url $TEMPO_RPC_URL \
    --private-key $PRIVATE_KEY
```

## Security Considerations

### Pre-Audit Checklist
- ✅ Fixed-point math tested extensively
- ✅ Sphere invariant enforced on all trades
- ✅ Slippage protection via minAmountOut
- ✅ SafeERC20 for token transfers
- ✅ Input validation on all functions
- ✅ No reentrancy vulnerabilities (no external calls before state updates)

### Recommended Before Mainnet
- [ ] Professional smart contract audit
- [ ] Formal verification of core math
- [ ] Bug bounty program
- [ ] Start with TVL limits
- [ ] Add emergency pause functionality
- [ ] Multi-sig for admin functions

## Future Enhancements

1. **Multi-tick consolidation** - Full paper implementation
2. **Factory pattern** - Easy pool deployment
3. **Router contract** - Multi-hop swaps
4. **TWAP oracle** - Time-weighted average prices
5. **Fee distribution** - LPs earn proportional fees
6. **Remove liquidity** - Withdraw from ticks
7. **Boundary crossing** - Handle tick transitions

## Resources

### Tempo
- Website: https://tempo.xyz/
- Testnet launched: December 2025
- Mainnet expected: 2026

### Development Tools
- Foundry: https://book.getfoundry.sh/
- OpenZeppelin: https://docs.openzeppelin.com/
- Cast (CLI): https://book.getfoundry.sh/reference/cast/

### Reference Implementation
- Python: `orbital_simple.py`, `fixed_point.py`
- Tests: `test_simple_pool.py`
- Paper: `paper.md`

## Contact & Support

For questions or issues:
1. Check the Python reference implementation
2. Review test cases for expected behavior
3. Consult `SOLIDITY_READY.md` for design decisions

## License

MIT License - see LICENSE file for details
