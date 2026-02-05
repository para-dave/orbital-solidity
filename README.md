# Orbital AMM (Solidity)

n-dimensional sphere-based AMM for stablecoin-style assets.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![Tests](https://img.shields.io/badge/tests-60%2F60%20passing-brightgreen)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-blue)](https://getfoundry.sh/)

## What’s Here

Two pool contracts:

- `contracts/OrbitalPool.sol`: simplified single-tick reference implementation (good for reading/learning).
- `contracts/OrbitalPoolV2.sol`: full implementation with multi-tick consolidation (interior/boundary/torus), routing, and LP withdrawal.

This repo intentionally ships only the Orbital Solidity code and this `README.md` (no extra status/roadmap docs).

## Quick Start

```bash
forge install
forge test
```

Expected: `60` tests passing.

## Deploy (example)

`script/DeployOrbital.s.sol` deploys mock ERC20s and an `OrbitalPool` with initial liquidity.

```bash
export PRIVATE_KEY=...
export TEMPO_RPC_URL=...

forge script script/DeployOrbital.s.sol --rpc-url "$TEMPO_RPC_URL" --broadcast
```

## Layout

```
contracts/
  FixedPointMath.sol
  OrbitalPool.sol
  OrbitalPoolV2.sol
  interfaces/IOrbitalPool.sol
test/
  FixedPointMath.t.sol
  OrbitalPool.t.sol
  OrbitalPoolV2.t.sol
  OrbitalPoolV2Consolidation.t.sol
  OrbitalPoolV2Torus.t.sol
  OrbitalPoolV2FullTorusStress.t.sol
script/
  DeployOrbital.s.sol
```

## Notes

- If you see an `etherscan config not found` warning during tests, it’s harmless unless you’re verifying on a block explorer.
- `addLiquidity()` after the first LP is proportional: it scales a tick by a single factor and only pulls the proportional amounts (any per-token “excess” in the `amounts` array is ignored/not transferred).
- Do not deploy to mainnet without a professional audit.

## License

MIT (see `LICENSE`).
