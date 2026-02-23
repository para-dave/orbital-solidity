# OrbitalPool explained (prose walkthrough)

This is an implementation-oriented explanation of the production contract:

- Canonical code: `contracts/OrbitalPool.sol`
- Fixed-point helpers: `contracts/FixedPointMath.sol`
- Mechanism paper: `../bullseye/paper.md` (sibling folder in this workspace)

The intent is to explain *what each piece of logic is doing* and *why it’s written this way*, not to be a full formal proof.

---

## 0) Conventions and paper notation (mapped to code)

### Fixed-point arithmetic (18 decimals)

All the AMM math uses 18-decimal fixed-point integers:

- `ONE = 1e18` means “1.0”
- `a.mul(b)` means `(a*b)/ONE`
- `a.div(b)` means `(a*ONE)/b`
- `sqrt(x)` returns a fixed-point square root

So when you see:

- `sqrtN`, it is `sqrt(n)` scaled by `1e18`
- `oneOverSqrtN`, it is `1/sqrt(n)` scaled by `1e18`

### Vectors used by the paper

The paper uses:

- `x` as the reserves vector (length `n`)
- `v = (1/sqrt(n), …, 1/sqrt(n))`
- `alpha = x · v` (parallel projection onto `v`)
- `w = x - alpha v` (orthogonal component)

In code:

- `oneOverSqrtN` is `1/sqrt(n)`
- `alphaTotal` is computed as `sum(x) / sqrt(n)` via `sumTotal.mul(oneOverSqrtN)`
- `||w||` is computed from `sumSquares - sum^2/n` (see `_fullTorusInvariantErrorFromSums`)

### Tick configuration vs tick *state*

Each tick has:

- **configuration**: `(r, k)`
  - `k == 0` → tick has no boundary plane (always “interior-capable” only)
  - `k > 0` → tick has a boundary plane `x·v = k` (a “cap” on the sphere)
- **dynamic state**: `pinned`
  - `pinned == true` means the tick is currently constrained to the boundary plane (paper “boundary tick”)
  - `pinned == false` means it is not on the plane (paper “interior tick”)

So “boundary vs interior” in the paper’s consolidation sense is *not* the same as `TickType`; it depends on `pinned`.

---

## 1) Why LP shares are proportional to `r`

The paper’s interior tick consolidation result (Tick Consolidation, Case 1) shows that when two ticks are locally interior and therefore arbitrage-aligned, their liquidity scales add:

`r_c = r_a + r_b`.

That makes `r` the natural additive liquidity unit. If we ever “combine” two ticks into one (as the paper does for trade calculations), then defining shares in units of `r` makes ownership additive too:

- tick A has `totalShares = r_a`
- tick B has `totalShares = r_b`
- combined tick has `totalShares = r_a + r_b`

This preserves proportional ownership whether you view them separately or as one consolidated tick.

So, for a tick’s first LP, the contract mints:

- `shares = r` (after setting `r` from the initialization deposit).

---

## 2) Tick creation (`createTick`)

`createTick(r, k)` stores the tick parameters and classifies it as:

- `TickType.Interior` if `k == 0`
- `TickType.Boundary` if `k > 0`

It sets `pinned = false` initially; pinning is a *runtime* state that changes via swaps.

---

## 3) Adding liquidity (`addLiquidity`)

### 3.1 First LP for a tick

The first LP path does five important things:

1. **Mint shares** in units of `r` (the paper’s additive interior-liquidity parameter).
2. **Set `r` from the deposit average**:
   - In the paper, the equal-price point has coordinates  
     `q_i = r(1 - 1/sqrt(n))`.
   - If the LP deposits an equal amount `xBase` per token at initialization, then  
     `r = xBase / (1 - 1/sqrt(n))`.
   - The code uses the *average* deposit to set `r` robustly:
     `newR = avg.div(oneMinusOneOverSqrtN)`.
3. **Rescale `k` to keep `k/r` constant (if `k>0`)**:
   - The paper’s comparisons are in normalized space (`kNorm = k/r`).
   - If we change `r` during initialization, we want the tick’s intended normalized boundary to remain the same.
4. **Set reserves** to the deposit amounts.
5. **Initialize `pinned`** if the initial reserves happen to lie on the plane `x·v = k` (within tolerance), and enforce the cap inequality `x·v <= k`.

Finally it checks the tick’s sphere invariant via `_checkSphereInvariant`.

### 3.2 Subsequent LPs (proportional scaling)

After a tick exists, the contract only allows adding liquidity by scaling the entire tick by *one factor*:

- Compute `minRatio = min_i(amount[i] / reserve[i])`
- Mint `shares = totalShares * minRatio`
- Scale:
  - each reserve by `(1 + minRatio)`
  - `r` by `(1 + minRatio)`
  - `k` by `(1 + minRatio)` (if `k>0`)
- Transfer only the proportional amounts required; any “excess” in the caller’s `amounts[]` is ignored

Why this restriction exists:

- It prevents value extraction via unbalanced deposits (classic AMM issue).
- It preserves the tick’s shape/invariants by construction (sphere equation is homogeneous under uniform scaling).
- With the initial-share rule above (`totalShares == r`), this also makes `shares` equal to `Δr` for each proportional add.

---

## 4) Removing liquidity (`removeLiquidity`)

Removal mirrors proportional add:

- `proportion = shares / totalShares`
- `scaleFactor = 1 - proportion`
- multiply every reserve, `r`, and `k` by `scaleFactor`

This preserves:

- the tick’s sphere invariant
- the cap inequality `x·v <= k`
- if the tick is pinned, the plane equality `x·v == k` (within tolerance)

---

## 5) Swaps and the paper mechanism

The production swap path is:

- `swap()` → `_swapFullTorusSegmented()`

This implements the paper’s mechanism:

1. Classify active ticks into “interior” vs “boundary” based on whether `k>0 && pinned`.
2. Consolidate:
   - interior ticks into one effective n-sphere with radius `rInt = sum r_i`
   - boundary ticks into one effective (n−1)-sphere magnitude `sBoundTotal = sum s_i`, where  
     `s_i = sqrt(r_i^2 - (k_i - r_i*sqrt(n))^2)`
3. Use the paper’s global “torus” invariant to compute the swap outcome on totals.
4. If a swap segment would cause a tick to change class (interior↔boundary), compute the exact crossover trade and segment the swap.

### 5.1 What `_getConsolidatedState()` computes

`_getConsolidatedState()` builds:

- `xTotal`: sum of reserves across all active ticks
- `sumTotal = sum(xTotal)`
- `sumSquaresTotal = sum(xTotal[i]^2)`
- `rInt`: sum of `r` over interior ticks
- `kBoundTotal`: sum of `k` over boundary ticks
- `sBoundTotal`: sum of `s` over boundary ticks

It also tracks the “next boundary” to cross, in normalized coordinates:

- `kMinInteriorNorm = min(k/r)` among *interior* ticks with `k>0`
- `kMaxBoundaryNorm = max(k/r)` among boundary ticks

### 5.2 Why crossings compare normalized values

The paper uses:

- `alphaIntNorm = alphaInt / rInt`
- `kNorm = k / r`

This is how you compare the consolidated interior point to boundaries of ticks that have different radii.

### 5.3 The segmentation loop (`_swapFullTorusSegmented`)

Each segment:

1. Solves as if *no* boundary crossing happens for the full remaining input.
   - If there are no boundary ticks: solve on a sphere (`_solveSphereNewXOut`).
   - Else: solve the torus invariant (`_solveTorusNewXOut`).
2. Computes the potential `alphaIntNorm` after that full segment.
3. If it crosses an interior/boundary threshold:
   - Solve the exact crossover `(dInCross, dOutCross)` with `_solveCrossoverAmounts`.
   - Apply that partial segment.
   - Flip `pinned` for the tick(s) at that crossing boundary (by normalized `k/r`).
   - Continue with the remaining input.

### 5.4 Why `_flipPinnedAtKNorm` flips “ties”

If multiple ticks share the same `k/r`, they cross simultaneously in normalized space. Flipping only one can produce a degenerate “next crossover” where the required input is ~0. Flipping all tied ticks matches the paper’s “they act like one pooled boundary” intuition.

---

## 6) How the global invariant is computed efficiently

The paper suggests tracking the totals:

- `S = sum_i x_i`
- `Q = sum_i x_i^2`

because a two-token swap only changes two coordinates, and those sums let you compute `alpha` and `||w||` in O(1) time.

### 6.1 Torus invariant error (`_fullTorusInvariantErrorFromSums`)

This matches the paper’s global invariant (fixed-point form):

- `alphaTotal = S / sqrt(n)`
- `||wTotal|| = sqrt(Q - S^2/n)`

and:

```
rInt^2 =
  (alphaTotal - kBoundTotal - rInt*sqrt(n))^2
  + (||wTotal|| - sBoundTotal)^2
```

The function returns `lhs - rhs` so “0” means “on invariant”.

### 6.2 Solving the output amount (`_solveTorusNewXOut`)

Given:

- we add `amountIn` to `x[inIdx]`
- we keep all other coordinates constant except `x[outIdx]`

`_solveTorusNewXOut` finds `newXOut` by **bracketed bisection** over `[0, xOutBefore]` until the invariant error is within tolerance.

Bisection is chosen for onchain robustness: it avoids Newton-derivative issues in fixed-point arithmetic and tends to be stable as long as the root is bracketed.

### 6.3 Applying totals back to ticks (`_applyGlobalReserves`)

After each segment computes the new totals `xTotal`, the pool must “deconsolidate” back to per-tick reserves while preserving each tick’s constraints.

It follows the paper’s decomposition:

1. Compute the orthogonal direction `u` from the totals:
   - `avg = sum/n`
   - `w_i = x_i - avg`
   - `u = w / ||w||` (unit vector)
2. For each boundary tick:
   - enforce plane: parallel component is `k*v`
   - enforce boundary sphere: orthogonal magnitude is  
     `s = sqrt(r^2 - (k - r*sqrt(n))^2)`
   - therefore set:
     - `x = k*v + s*u`
3. For the consolidated interior:
   - `alphaInt = alphaTotal - kBoundTotal`
   - `||wInt|| = ||wTotal|| - sBoundTotal`
   - so:
     - `xInt = alphaInt*v + ||wInt||*u`
4. Split `xInt` across interior ticks proportionally by `r` (paper’s interior consolidation).

This preserves:

- every boundary tick’s plane and sphere invariants
- every interior tick’s sphere invariant (and `x·v <= k` if it has a cap)

---

## 7) View functions / diagnostics

- `checkInvariant(tickId)` checks the per-tick sphere equation.
- `isOnBoundary(tickId)` checks `x·v == k` within `TOLERANCE`.
- `getGlobalState()` recomputes totals from ticks (diagnostic convenience).

`getPrice()` uses the “largest tick” and the sphere gradient formula `p = (r - xB)/(r - xA)`. In a multi-tick consolidated system, “the” price is really defined by the consolidated global state; this function is mainly for UI/testing convenience.
