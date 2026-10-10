# Adaptation for the IMD `evm_contracts` launch on Robinhood Chain

The project arrived already shaped for the launch: one contract, `IMD6900PerpsLaunch`, four static constructor
arguments (`0x8366a39CC670B4001A1121B8F6A443A643e40951`, `10000`, `0x35da9c0303507ddf708e87f2568eddf12c47a059`,
`0x35da9c0303507ddf708e87f2568eddf12c47a059`), nonpayable, no call to anything that exists before it, no
DELEGATECALL / CALLCODE / SELFDESTRUCT, no proxy, no token. Nothing about the launch shape, the hook's permissions
(`IMD6900PerpsLaunch.FLAGS`), its fee handling (the pool's static fee, no return deltas, no dynamic fee) or the
constructor arguments changed. `foundry.toml`, `remappings.txt` and `lib/` are untouched; `launch.json` is not written.

What changed is the audit of the imported code (jobs ea1c84c3 and d07ab5c6, then the import audit carried by this
task). Each finding was reproduced against the code as it arrived before anything was fixed:

| finding | reproduced | result |
|---|---|---|
| 90ab2e9d medium: `compound()`'s Pons guard is void when the hook cannot read the reference | yes: the proof (`Proof_90ab2e9df0ee.t.sol`) failed with the attacker at 10.03198 ETH | fixed |
| 2f33186a medium: `addLiquidity()` pairs at any price inside the 30% band, so a push, an addition and a sell-back pay out of the pool's position | yes: the proof (`Proof_2f33186a2ba8.t.sol`) failed with the attacker at 10.01309 ETH | fixed |
| 62af2101 low: the hook's constructor accepts a zero fee address, so `flush()` burns 3% | yes: `feeAddress = feeAddress_` was stored unchecked; only `updateFeeAddress` refused zero | fixed |
| 93cc8561 low: `feeBps` starts at 1,000 bps while the pool's fee is 100 bps | yes: `uint256 public feeBps = 1_000` regardless of `poolFeePips` | fixed |
| 7664c5d4 info: coverage | not a defect | nothing to fix; the 41 entry points are listed below and the ten Ownable ones now have a test |

Both proofs pass on the fixed code (they were run from `test/scratch/`, which is not part of the submission; the
same scenarios are held by `test/AuditFixes.t.sol`).

## Changes

### `src/IMD6900PerpPool.sol`

1. **`compound()` refuses when the hook has no reference** (finding 90ab2e9d). `IMD6900PerpHook.deviationBps()`
   returns 0 when `ponsPriceX96()` is 0, so "no reference" read as "on price" in exactly the states where the band is
   off too (graduated on Pons with no pool recorded yet, zero reserves, an unreadable or mispointed curve). The guard
   now reads `ponsPriceX96()` first and reverts `NoPonsReference()` when it is 0, then applies the existing 1%
   `OffPons` check. The `IBandView` interface gained `ponsPriceX96()`; the hook already exposed it.
   Test: `test_Fix_CompoundRefusesWithoutAReference` (the graduated-phase-1 state and the unreadable-curve state both
   refuse; the finding's sandwich adds nothing and loses the fee; with the reference back, compound runs).

2. **`addLiquidity()` runs under the same guard** (finding 2f33186a). It paired the caller's ETH and coin at the
   pool's spot price with no bound against Pons, and the position it deepens belongs to the pool, so a push inside the
   30% band followed by anyone's addition and a sell-back paid the pusher out of the pool's position. It now calls the
   shared `_requireOnPons()` (`COMPOUND_MAX_DEV_BPS`, 1%, and a readable reference) before taking funds. The constant
   keeps its name; its doc now covers both functions. The owner's own re-deposits go through the same check: the owner
   can repoint the curve (`setCurve`) if the reference is wrong, and `open()` is unaffected (it sets the price itself).
   Test: `test_Fix_AddLiquidityOnlyAtThePonsPrice` (a 24% push: the addition reverts `OffPons`, the round trip loses
   the fee; no reference: `NoPonsReference`; at the Pons price anyone still deepens the pool).

### `src/IMD6900PerpHook.sol`

3. **Zero fee address refused at construction** (finding 62af2101). The constructor reverts `ZeroAddress()` for
   `feeAddress_ == address(0)`, the check `updateFeeAddress` already had. Through the launch, the hook's create2 fails
   and `IMD6900PerpsLaunch` reverts `BadHook`. This launch passes the team wallet, so the deployed instance was never
   affected; the check protects a relaunch or a manifest typo.
   Test: `test_Fix_NoZeroFeeAddressAtConstruction`.

4. **`feeBps` and `perpFeeBps` derived from `poolFeePips`** (finding 93cc8561). The hook's own rule says the two
   rates are what the engine reads to model its solvency and "must be kept equal to the pool's real fee"; they were
   hard-coded to 1,000 and 100 bps. Both are now `poolFeePips / 100` at construction (100 bps for this launch's 10,000
   pips; `perpFeeBps` capped at `MAX_PERP_FEE_BPS`, which only matters for a pool fee above 10%). The launch recipe
   asks for exactly this ("derive what follows from other arguments") and removes a post-deployment `lowerFee(100)`.
   `lowerFee` keeps its only-lower rule and its `MIN_FEE_BPS` floor; `setPerpFeeBps` is unchanged.
   Test: `test_Fix_FeeBpsFollowsThePoolFee` (10,000 pips → 100 bps on both; 3,000 pips → 30 bps; `lowerFee` still
   refuses a raise and anything under the floor).

### `test/AuditFixes.t.sol`

- The four tests above, plus `test_OwnableEntryPointsOnBoth` (the ten `Ownable` entry points the hook and the pool
  inherit from solady, see the list below) and `test_OwnerAlwaysTakesTheLiquidityBack` (the property the brief asks to
  keep: with an unreadable reference, a dead engine on the hook and a 1 bps band, the owner removes all liquidity and
  gets the ETH and coin back; `removeLiquidity` does not go through the new guard).
- `test_Fix_AnAdditionLeavesTheEarnedFeesInThePool` parks the Pons reference at the pool's price before its addition:
  the six round trips it runs first leave the pool ~2.5% off Pons, and an addition now runs only within 1% of it. The
  test still checks what it did (the earned fees stay in the pool).
- Mocks `PhaseOneFactory` and `GraduatingCurve` (the Pons state in which the hook has no reference) were added.

## Behaviour kept

- The hook's permissions, `FLAGS`, the static pool fee, no return deltas, no dynamic fee: Uniswap's router quotes the
  pool as before. `test_DeploysOnAFreshChain`, `test_FitsOneTransaction`, `test_PassesTheAdmissionScan` pass unchanged.
- The owner can always take all of the pool's liquidity back (`removeLiquidity`): the hook only checks the caller is
  the pool and the range is full. The new guard touches `compound` and `addLiquidity` only.
- The perps engine is not in this launch; `setPerpEngine` on both contracts is unchanged.
- No change to `IMD6900PerpsLaunch.sol`, `script/Owner.s.sol` or `test/RobinhoodFlow.fork.t.sol` (it uses `compound`
  only once the pool is within 1% of Pons and never calls `addLiquidity`).

## The 41 entry points

For the audit that follows (a coverage ratio below 1 blocks the launch), the non-view entry points, by contract:

**IMD6900PerpHook (25)**: `lowerFee`, `setPerpFeeBps`, `setPerpEngine`, `setSweepFailOpen`, `setBand`,
`setFeeExempt`, `updateFeeAddress`, `renounceFeeAddress`, `flush`, `beforeInitialize`, `afterInitialize`,
`beforeAddLiquidity`, `afterAddLiquidity`, `beforeRemoveLiquidity`, `afterRemoveLiquidity`, `beforeSwap`,
`afterSwap`, `beforeDonate`, `afterDonate`, `receive`, and from solady's `Ownable`: `transferOwnership`,
`renounceOwnership` (reverts `NoRenounce`), `requestOwnershipHandover`, `cancelOwnershipHandover`,
`completeOwnershipHandover`.

**IMD6900PerpPool (16)**: `setFeeSink`, `setHook`, `setPerpEngine`, `setCurve`, `removeLiquidity`, `open`,
`addLiquidity`, `compound`, `addFees`, `unlockCallback`, `receive`, and from solady's `Ownable`: `transferOwnership`,
`renounceOwnership` (reverts `NoRenounce`), `requestOwnershipHandover`, `cancelOwnershipHandover`,
`completeOwnershipHandover`.

**IMD6900PerpsLaunch (0)**: constructor only; `pool()`, `hook()`, `salt()`, `FLAGS()` are views.

## Checks run

`forge build` (the project's own configuration, offline) and `forge test`: 26 tests pass, the fork suite skips
without `ROBINHOOD_RPC_URL`. The two audit proofs pass against the fixed code from `test/scratch/`.
