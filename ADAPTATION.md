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

## Revision of the accepted submission

The sections above record the accepted earlier round. The following changes address the reopened review; where
an earlier description says a function was unchanged, this section describes the current result. No build settings,
dependencies, constructor arguments, hook flags, swap fees, return deltas, withdrawal rights, or engine launch scope
were changed. `.imd-responses.json` answers all 14 supplied finding IDs.

### Reproduction and changes in this revision

1. **b3778ef6 — bounded, cheaper salt mining (`src/IMD6900PerpsLaunch.sol`).** Despite the brief's note that its
   attached proof passed elsewhere, copying the unmodified `Proof_b3778ef613a8.t.sol` into `test/scratch/` and running
   `forge test --offline -vv` here reproduced the failure: factory `0xBEEF`, salt 50149, 132,475 tries, **21,218,454
   gas**. The baseline `test_FitsOneTransaction` misleadingly metered only 3,760 gas for Solidity `new` in this Foundry
   version. The constructor still searches sequential salts from its own address and chooses the first matching
   address, but hashes eight candidates per batch before branching. Its temporary scratch preimage uses bytes
   0x00..0x5f; the saved free-memory pointer is restored and the zero slot is untouched. The search stops after
   **134,144 attempts** with `NoSalt`, instead of allowing a million iterations to run out of transaction gas.
   This bound was selected against the measured deployment/intrinsic budget, not an average search length.

   `test/IMD6900PerpsLaunch.t.sol` now uses raw CREATE and asserts that more than 3M gas was actually metered.
   `test/LaunchAdmission.t.sol` adds raw CREATE2 under a capped call budget, calldata/intrinsic accounting, 100k of
   factory headroom, the supplied salt and a 24-salt sample, first-match fuzzing, and a fixed address/hash regression
   independent of the changed bytecode. The latter still takes exactly 132,475 tries, now about **11.875M mining
   gas**, down from 17.090M. A separate no-match vector (hash 9044 at the same address) exhausts the full limit and
   returns `NoSalt` in **12,023,472 gas**. The measured deployment overhead plus an exhaustive-search ceiling,
   winning-batch margin, intrinsic gas and factory headroom totals **16,697,989**, below 16,777,216. This budget check
   is conservative accounting, not a simulation of an unknown production factory wrapper.

   No finite search guarantees a hash match at every address. Under uniform hashing the residual miss rate is
   approximately 1 in 3,600. README now requires admission to rehearse the **actual** factory and resolved salt
   (`test_ActualFactorySaltWhenProvided`), followed by the deployment service's complete transaction simulation.
   A miss or an over-budget simulation requires a new launch number and a fresh rehearsal, not a higher gas limit
   or changed constructor arguments. The actual factory and launch number were not supplied in this revision.

2. **411b0e14 — collect fees before sizing a one-sided compound (`src/IMD6900PerpPool.sol`).** Six buy/sell round
   trips, an on-price reference, 1 ETH idle and zero idle coin reproduced `ZeroLiquidity` despite earned coin fees.
   If either idle balance is zero and the position is non-empty, `compound` now calls `_modify(0)` to collect its
   fees, rereads both balances, then applies the existing minimums and liquidity calculation. The Pons guard still
   executes first and a later failure rolls back the collection. The NatSpec no longer claims the hook skims coin.
   `test/RevisionFixes.t.sol` covers one-sided and entirely empty idle balances with earned fees, minimum rollback,
   the reference guards, and a completely drained position. When there are no matching fees or coin, compounding
   still cannot manufacture coin: README documents supplying coin, compounding on price, then withdrawing the
   resulting liquidity to recover unmatched idle ETH. No new sweep privilege or entry point was introduced.

3. **f44ad048 — keep the engine model equal to the static pool fee (`src/IMD6900PerpHook.sol`).** Reproduced an
   exempt caller reading zero while v4 collected 0.001 ETH on its 0.1 ETH trade; also reproduced engine model rates
   of 0 and 1,000 bps against the 100 bps pool. `feeFor` now derives its answer only from `poolFeePips`; exemptions
   still control the band. `perpFeeBps` is initialized to the actual rate without a model-only cap, and its setter
   accepts only that rate. `lowerFee` remains in the ABI and refuses changes with `InvalidFee`, as it already did
   for every input at this launch's 1% rate. Its nonpayable mutability is retained for ABI compatibility (solc notes
   that its implementation could be view). The legacy limit getters/events remain; comments explain their status.
   No swap fee, forwarding split, fee recipient, permission flag or routing behavior changed. Tests verify the
   actual v4 fee growth for an exempt engine, owner-only setters, refused mismatches, and 0.3%/20% static-fee models.

4. **af62a280 — guard the opening price (`src/IMD6900PerpPool.sol`).** Reproduced successful opening at 1e9 coin/ETH
   while Pons reported 1.25e9, a 2,000 bps deviation. Immediately after `initialize`, `open` now runs the same
   `_requireOnPons` used by additions and compounding. An unreadable or stale reference rolls back initialization,
   token/curve state, hook pool ID and transfers. Tests cover both failures and a successful retry at the refreshed
   price. README tells the owner to recompute the quote when this guard rejects a stale script simulation.

5. **0b0abb0c — units clarified, formula preserved.** Reproduced the reciprocal asymmetry, but the hook's price
   APIs explicitly define coin per ETH and the project tests use those units. The proposed symmetric max/min metric
   would change the trading policy and would not itself produce symmetric +/-30% ETH-per-coin bounds. No engine is
   in this launch to establish a conflicting unit requirement. The exact example with curve quote reserve 1.3 ETH
   reads about **3,000**, not the reported 2,307 bps; the general reciprocity observation is valid. Hook NatSpec,
   README and a regression now state the existing formula and its approximate -23.08%/+42.86% reciprocal range.
   This is disputed as a contract defect; the documentation ambiguity is resolved.

6. **efcd809e, 647fd79c, 24e73753 — owner and migration runbook (`README.md`).** Reproduced an owner transferring
   both contracts to an unusable nonzero address, redirecting the pending flush share, configuring a no-code engine
   that blocks trading, and moving an empty pool's price for zero amounts within the band. These are authorized
   powers or consequences of the explicitly required full withdrawal capability. They remain unchanged and are
   held by tests in `test/RevisionFixes.t.sol`; existing ownership and withdrawal regressions also pass. The runbook
   recommends independent two-step handovers, records curve/band/fee/sweep/engine powers, and requires settling
   positions and unwiring the old engine on both contracts before draining a pool used as a mark.

7. **bbd87e2e — sink compatibility coverage (`test/RobinhoodFlow.fork.t.sol`, `test/RevisionFixes.t.sol`, README).**
   Reproduced a contract with no `addFees` accepting configuration but reverting `flush`; the full hook balance
   remains intact and clearing the sink restores forwarding. This is documented as an owner configuration
   requirement rather than changing fee handling. The optional fork flow now calls `flush` after configuring the
   real Pons launcher and checks the 97% forwarding split through its 70/10/20 payees (plus the hook's 3% share).
   That live ABI integration is **not verified here**: `ROBINHOOD_RPC_URL` is unset and the suite skips.

8. **Imported findings 90ab2e9d, 2f33186a, 62af2101, 93cc8561.** They do not reproduce on the accepted starting tree:
   both supplied sandwich proofs pass, `NoPonsReference`/`OffPons` prevent the additions, zero fee address construction
   reverts `BadHook`, and both model rates start at 100 bps for this launch. The previous fixes were preserved.
   The new model work in item 3 addresses the different, reproducible post-construction inconsistency.

### Entry-point review: 41 of 41 answered

Read all three source contracts, `Owner.s.sol`, the project tests, the protected admission harness, and the relevant
vendored BaseHook/Ownable/Uniswap permission and liquidity code. The compiled ABIs still contain exactly 25 hook and
16 pool non-view entry points (including receive). Constructors and view helpers were also reviewed; the launch
has no non-view runtime entry point. This is review coverage, not a claim of formal correctness or live dependency
verification. Findings are disposed of above and in `.imd-responses.json` (including coverage finding 7664c5d4).

| IMD6900PerpHook entry point | Answer |
|---|---|
| lowerFee | Owner only; static fee cannot change; always InvalidFee. Model fix tested. |
| setPerpFeeBps | Owner only; only the actual static fee is accepted. Model fix tested. |
| setPerpEngine | Owner only; zero disables; incompatible engine can block swaps. Intended replacement power. |
| setSweepFailOpen | Owner only; intended escape hatch bypasses unavailable pre-sweep; trust documented. |
| setBand | Owner only; nonzero width; existing policy and units retained. |
| setFeeExempt | Owner only; band exemption only; does not exempt v4 fees. |
| updateFeeAddress | Owner only, nonzero, disallowed after renunciation; affects pending ETH as documented. |
| renounceFeeAddress | Owner or current fee address; one-way share redirection to pool. |
| flush | Public; 97/3 split unchanged, renounced share goes to pool; sink failure rolls back transfers. |
| beforeInitialize | PoolManager only, sender must be pool; one pool, ETH/token, matching static fee and spacing. |
| afterInitialize | PoolManager only; unimplemented, reverts; permission disabled. |
| beforeAddLiquidity | PoolManager only, sender must be pool, full range. |
| afterAddLiquidity | PoolManager only; unimplemented, reverts; permission disabled. |
| beforeRemoveLiquidity | PoolManager only, sender must be pool, full range; no band or hook engine withdrawal guard. |
| afterRemoveLiquidity | PoolManager only; unimplemented, reverts; permission disabled. |
| beforeSwap | PoolManager only, matching pool; fail-closed pre-sweep and transient start price recorded after sweep. |
| afterSwap | PoolManager only; band judged before best-effort post-sweep; crossing rule retained. |
| beforeDonate | PoolManager only; unimplemented, reverts; permission disabled. |
| afterDonate | PoolManager only; unimplemented, reverts; permission disabled. |
| receive | Public payable; accepts stray ETH for flush, no state-changing callback. |
| transferOwnership | Owner only, rejects zero; incorrect nonzero recipient can strand control; handover recommended. |
| renounceOwnership | Owner only; always NoRenounce. |
| requestOwnershipHandover | Candidate requests its own handover; 48-hour expiry, no ownership change. |
| cancelOwnershipHandover | Candidate clears only its own request. |
| completeOwnershipHandover | Owner only; valid pending request required and consumed; no coupling to pool ownership. |

| IMD6900PerpPool entry point | Answer |
|---|---|
| setFeeSink | Owner only; zero retains fees locally, other addresses need code; payable addFees compatibility is operational. |
| setHook | Owner only; hook is set once in launch constructor before transfer to the specified owner. |
| setPerpEngine | Owner only; explicit zero escape hatch retained so broken engine cannot trap withdrawals. |
| setCurve | Owner only; nonzero; repoints trusted external reference, with fail-closed pairing guards. |
| removeLiquidity | Owner only, nonreentrant; pays principal and earned fees; pool engine check can be disabled by owner. |
| open | Owner only, once, nonreentrant; validates token/curve, now requires readable on-price Pons reference atomically. |
| addLiquidity | Public, nonreentrant; caller funds only, guarded reference/price, refunds principal remainder, retains fees. |
| compound | Public, nonreentrant; reference guard first, optional fee collection, balance minimums, position stays pool-owned. |
| addFees | Public payable; forwards only msg.value to configured sink or retains it; never sweeps existing balance. |
| unlockCallback | PoolManager only; full-range modify; settles/takes each signed currency delta and preserves principal accounting. |
| receive | Public payable; holds withdrawal/fee ETH. |
| transferOwnership | Owner only, rejects zero; incorrect nonzero recipient can strand liquidity; handover recommended. |
| renounceOwnership | Owner only; always NoRenounce. |
| requestOwnershipHandover | Candidate requests its own handover; 48-hour expiry, no ownership change. |
| cancelOwnershipHandover | Candidate clears only its own request. |
| completeOwnershipHandover | Owner only; valid pending request required and consumed; no coupling to hook ownership. |

All ten inherited ownership functions are exercised by `test_OwnableEntryPointsOnBoth`. The owner's full-liquidity
recovery with an unreadable curve and broken hook engine remains covered. No timelock address, engine, token,
production factory address or deployment number was invented; the launch still names no coin in its constructor.

### Validation in this revision

Local reproduction and checks use Foundry with the unchanged project configuration and vendored dependencies.
The three supplied proofs were run unmodified from `test/scratch/`. The final build and test results are recorded
below after the last check. No Slither, Mythril, live deployment, signing, or network verification is claimed.

Final results:

- `forge build`: passed with the existing configuration (non-fatal compiler/lint warnings only).
- `forge test`: **58 passed, 0 failed, 2 skipped**, including 256 first-match fuzz cases and all three unmodified
  supplied proofs from scratch. The delivered suite accounts for 55 of those passes; scratch contributes three.
- Skipped: the Robinhood fork without `ROBINHOOD_RPC_URL`, and the actual-factory rehearsal without production
  `IMD_PROJECT_FACTORY` / `IMD_PROJECT_SALT_0`. The rehearsal's supplied-input branch was separately tested offline
  using the review proof's test fixture (`0xBEEF`, salt 50149); it passed, not a claim about the production factory.
- Fresh-chain deployment, dynamic-fee rejection, permissions, owner liquidity recovery, metered deployment and
  forbidden-opcode scans all passed. Unmodified reviewer gas proof now measures 7,098,794 gas at its new
  bytecode-dependent launch address; the pinned expensive search still verifies the optimization independently.
- Artifacts: launch init/runtime 20,107/308 bytes; hook 9,896/8,845; pool 8,949/8,669. Constructor argument words also
  fit the 49,152-byte init limit; all runtimes fit 24,576. Constructors are nonpayable with supported static arguments,
  and none of the three artifacts has an external library link.
- `git diff --check` passed; all 14 JSON responses validate. Protected configuration/dependencies are unchanged.
