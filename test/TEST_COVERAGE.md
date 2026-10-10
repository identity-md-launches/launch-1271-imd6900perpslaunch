# IMD6900 perps test coverage

The new suites extend the accepted tests without changing application code, dependencies, configuration, permissions, or constructor arguments. Run `forge build` and `forge test` from the repository root. No additional dependencies are needed.

## Stateful properties

`PerpsLiquidity.invariant.t.sol` deploys the production launch and a real vendored v4 PoolManager. Three funded actors contribute, donate, and receive refunds or withdrawals; a router swaps in both directions with exact-input and exact-output amounts. The owner makes partial and full withdrawals, including after an unavailable reference. Calls are selected explicitly: unrelated helper methods and token minting cannot enter random sequences.

- After every call, manager plus pool balances equal initial capital plus external inflows minus external distributions, independently tracked from payer/recipient balances and swap settlement deltas.
- All active liquidity belongs to the pool's full-range position.
- Additions cannot charge more than supplied; compounding cannot pay its caller the position's fees.
- The owner can withdraw the whole position and receive at least its independently calculated v4 principal in both currencies after every sequence prefix. A snapshot is restored after each liveness probe, so probing does not drain the next sequence step.
- Full removal followed by adding again exercises an empty position without reopening the initialized pool.

`PerpsFees.invariant.t.sol` separately sequences hook deposits, public flushes, direct pool payments, fee-recipient changes, fee renunciation, and working/reverting sinks. Ghost balances check each recipient, retained pool ETH, sink receipts, and total conservation. Failed forwarding must leave every balance unchanged. Renunciation is irreversible and redirects all subsequent hook receipts to the pool's fee path.

Both campaigns use inline configuration: 256 runs, depth 64, and `fail-on-revert = true`. Expected failures are caught only when their exact error matches; unexpected failures fail the campaign. Deterministic lifecycle tests prove the main handler branches are reachable. Deposits/donations are bounded by funded actors; swaps are bounded by available reserves. The liquidity handler aligns the external curve to the current pool price before valid additions, compounding, and swaps to keep accounting paths reachable. Independent integration tests exercise the actual band, missing references, displacement, and corrections without that alignment.

Stateless properties run 1,000 examples each: add/remove roundtrips cannot create value; actual v4 rounded-up debts fit both liquidity funding budgets across the full tick range; the rational reserve price has bounded rounding error and scales consistently; flushes conserve every wei and round the 3% share down by less than one wei. Zero, one, full balances, range endpoints, and the liquidity type cap also have explicit examples.

## Complete entry-point inventory: 41/41

This is a mapping of the compiled ABI's **state-changing callable surface**, not a claim of 100% line or branch coverage. The hook has 25 entries and the pool 16, counting each `receive()` and all ten inherited ownership functions. View functions and launch constructors are addressed separately below.

Suite abbreviations: **F** = `PerpsFailurePaths.t.sol`; **B** = `PerpsBandIntegration.t.sol`; **R** = `PerpsReferenceAndOwnership.t.sol`; **L** = `PerpsLiquidity.invariant.t.sol`; **E** = `PerpsFees.invariant.t.sol`; **X** = `PerpsExactLaunch.t.sol`; **A** = accepted `AuditFixes.t.sol`; **V** = accepted `RevisionFixes.t.sol`.

| # | Contract / entry point | Tests and checked failure paths |
|---|---|---|
| 1 | Hook `receive` | E: random deposits, zero and dust, conservation after flush |
| 2 | Hook `beforeInitialize` | F: manager/caller authentication, wrong currencies/fee/spacing, second initialization; X: requested permissions |
| 3 | Hook `afterInitialize` | F: non-manager rejected; manager receives `HookNotImplemented`; X: permission disabled |
| 4 | Hook `beforeAddLiquidity` | F: only pool, both full-range endpoints; L: actual v4 additions |
| 5 | Hook `afterAddLiquidity` | F: non-manager rejected; manager receives `HookNotImplemented`; X: permission disabled |
| 6 | Hook `beforeRemoveLiquidity` | F: only pool and full range; L: full owner withdrawal after every prefix |
| 7 | Hook `afterRemoveLiquidity` | F: non-manager rejected; manager receives `HookNotImplemented`; X: permission disabled |
| 8 | Hook `beforeSwap` | F: foreign pool, statuses 0/1/2/max, reverted/short response, low gas, engine self-swap; L: both directions and amount signs |
| 9 | Hook `afterSwap` | B: atomic band rejection, corrections, crossing, nested sweep order; F: best-effort post-sweep and zero return delta |
| 10 | Hook `beforeDonate` | F: non-manager rejected; manager receives `HookNotImplemented`; X: permission disabled |
| 11 | Hook `afterDonate` | F: non-manager rejected; manager receives `HookNotImplemented`; X: permission disabled |
| 12 | Hook `lowerFee` | F: unauthorized caller; V `test_FeeModelAlwaysMatchesStaticFee`: owner also cannot change the static rate |
| 13 | Hook `setPerpFeeBps` | F: unauthorized caller; V: only actual static pool rate accepted; engine/exempt swaps still charged |
| 14 | Hook `setPerpEngine` | F: unauthorized caller, unavailable/malformed/healthy engines and gas budgets; B: real recursive engine swaps |
| 15 | Hook `setSweepFailOpen` | F: authorization, availability fallback; explicit incomplete/oversized sweeps remain rejected |
| 16 | Hook `setBand` | F: unauthorized/zero rejected; R: new owner controls it; A: tightest band cannot trap liquidity |
| 17 | Hook `setFeeExempt` | F: unauthorized caller; B: exemption and revocation change band enforcement while preserving fee |
| 18 | Hook `updateFeeAddress` | F: unauthorized and rejecting-recipient recovery; E: current-recipient accounting and permanent renunciation; A: zero rejected |
| 19 | Hook `renounceFeeAddress` | E: fee recipient or owner succeeds, outsiders/repeats rejected, permanent routing; R: independent of new owner |
| 20 | Hook `flush` | E: public access, zero/dust/max-uint128 rounding, idempotence and failing sink; F: final recipient failure rolls back earlier pool payment |
| 21 | Hook `transferOwnership` | A `test_OwnableEntryPointsOnBoth`: owner/non-owner/zero; R: old owner loses access and pool ownership remains independent |
| 22 | Hook `renounceOwnership` | A: owner gets `NoRenounce`; F: non-owner gets `Unauthorized`; R: still blocked after handover |
| 23 | Hook `requestOwnershipHandover` | A: normal and expired request; R: exact 48-hour boundary, candidates grant no immediate power |
| 24 | Hook `cancelOwnershipHandover` | A: completion of canceled request fails; R: one candidate cannot cancel another |
| 25 | Hook `completeOwnershipHandover` | A: missing/canceled/expired/unauthorized; R: inclusive expiry, consumed request, old-owner revocation |
| 26 | Pool `receive` | L: donations and real v4 removal settlement; E: plain ETH stays idle even with a sink configured |
| 27 | Pool `setFeeSink` | F: unauthorized; E: enabled/disabled/reverting sinks; A: EOA rejected; V: incompatible sink recovery |
| 28 | Pool `setHook` | X: launch wires it; F: unauthorized and repeat setter rejected |
| 29 | Pool `setPerpEngine` | F: unauthorized, healthy/unhealthy/broken book, owner disables broken withdrawal guard and recovers funds |
| 30 | Pool `setCurve` | F: unauthorized; A: zero rejected and unreadable curve replaced; R: graduation and unavailable-reference states |
| 31 | Pool `open` | X: remains unopened at launch; F: owner-only, no hook, duplicate, zero token/budget, initialization rollback and retry; V: stale/unreadable reference |
| 32 | Pool `addLiquidity` | L: several actors/refund recipients; F: not open, zero/dust, reentrancy, false-return token and roundtrip; A: missing/off-price reference |
| 33 | Pool `compound` | L: random idle deposits and earned fees, no caller profit; F: closed/reentrant; A/V: no reference, off-price, minimums and collection rollback |
| 34 | Pool `removeLiquidity` | L: partial/full/empty-refill; F: unauthorized, zero, unhealthy/broken/healthy book, ETH/token payout failures and atomic rollback |
| 35 | Pool `addFees` | E: random public payments with sink disabled/enabled/reverting; exact per-destination accounting |
| 36 | Pool `unlockCallback` | F: non-manager rejected; L/F: real unlocks exercise adding, fee collection, removal, both currencies' settlement and payouts |
| 37 | Pool `transferOwnership` | A: owner/non-owner/zero and transfer back; F: authorization; R: old owner loses privileges |
| 38 | Pool `renounceOwnership` | A: owner gets `NoRenounce`; F: non-owner gets `Unauthorized`; R: blocked after handover |
| 39 | Pool `requestOwnershipHandover` | A: normal and expired request; R: candidates, request isolation and exact expiry |
| 40 | Pool `cancelOwnershipHandover` | A: canceled request cannot complete; R: another candidate's request survives |
| 41 | Pool `completeOwnershipHandover` | A: missing/canceled/expired/unauthorized; R: inclusive expiry, consumed request, old-owner revocation |

## Deployment, reads, and limits

X traces construction using the exact four brief arguments on chain ID 4663 with no code at the manager address. Only the launch, pool and hook are created; constructor calls may reach only the newly created pool/hook. It verifies the CREATE2 preimage, the independent permission mask `0x2ac0`, static fee, explicit team ownership, and absence of coin/curve/engine setup. Creation/runtime opcode scans cover all three contracts and runtime/init-code size limits. Invalid constructor arguments are rejected.

The accepted `LaunchAdmission.t.sol` remains the metered one-transaction/miner regression suite, including raw CREATE2, gas headroom, exhausted search, first matching salt, and an optional exact-factory rehearsal. R checks reserve and graduated v4 reference prices, currency orientation, unreadable data, and the public ownership/fee views. L checks `poolKey`, `liquidity`, owners and fee consistency through actual use. The accepted audit regressions remain in place; none are removed or weakened.

The production engine is outside this launch. Engine doubles test the documented sweep/book interfaces and recursive v4 settlement, not a future engine's solvency. These are offline tests with local coin and Pons doubles; the existing `RobinhoodFlow.fork.t.sol` still needs `ROBINHOOD_RPC_URL` to verify live state. The existing exact-factory rehearsal needs its factory/salt environment inputs. Both skip without those inputs; no test writes environment variables. No new confirmed implementation defect was found by these checks.
