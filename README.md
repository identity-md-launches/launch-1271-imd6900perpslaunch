# IMD6900 perps hook: deployed by the IMD swarm on Robinhood Chain

The Uniswap v4 hook and pool behind IMD6900's in-pool perps on Robinhood Chain, packed so the IMD swarm can deploy
them with IMD's `evm_contracts` launch: one contract, constructor arguments only, nothing called after.

IMD6900 trades on Robinhood Chain as a Pons coin. This is its second market: an ETH / IMD6900 Uniswap v4 pool the
protocol owns in full, that its perps engine trades against, held near the coin's price on Pons.

- `src/IMD6900PerpHook.sol`: the hook. Before any swap that isn't the perps engine's own, it asks the engine to close
  every position that trade would sink, at the price before it moves; a sweep that can't finish reverts the trade (no
  bad debt outranks always-tradeable, with an owner escape hatch for a broken engine). After the swap it refuses to
  leave the pool further than `maxDeviationBps` (30%) from Pons in **coin per ETH**, unless the trade moved it closer. It
  uses no return deltas and no dynamic fee, so Uniswap's router quotes the pool on its own. Only its pool may
  initialize it or add and remove liquidity, full range only.
- `src/IMD6900PerpPool.sol`: the pool's one position. The owner opens it once the coin trades on Pons (the price, the
  ETH, the coin), within 1% of a readable Pons price. Anyone can deepen it under the same guard; only the owner can
  take liquidity out, and never while that would leave an open perps position liquidatable. The pool's static fee accrues to this position: the
  protocol earns it.
- `src/IMD6900PerpsLaunch.sol`: what the swarm deploys. Uniswap v4 reads a hook's permissions from the low 14 bits of
  its address, so the hook must sit at a mined address, and IMD deploys from its own deployer, which nobody can mine
  for in advance. So this constructor does it: it creates the pool, tries CREATE2 salts from itself until the hook's
  address carries exactly the hook's flags (one in 16,384 on average, done in assembly), creates the hook there, wires
  the pool to it and hands both to `owner`. It calls nothing that existed before it.

The perps engine (`PerpEngine`, `PerpVault`) is not in this launch: it reads the pool's live price when it is built,
so it comes after the pool opens, deployed by the owner and wired with `setPerpEngine` on the hook and the pool. Until
then the pool is spot only.

## The launch (`evm_contracts`, Robinhood Chain, chain id 4663)

One contract, `IMD6900PerpsLaunch`, with four constructor arguments, in order:

| | | |
|---|---|---|
| `poolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | Uniswap v4's PoolManager on Robinhood Chain |
| `poolFee` | `10000` | the pool's static fee in hundredths of a bip (1%), the hook's too |
| `owner` | `0x35da9c0303507ddf708e87f2568eddf12c47a059` | the team wallet: runs the pool and the hook, later its timelock |
| `feeAddress` | `0x35da9c0303507ddf708e87f2568eddf12c47a059` | the hook's fee address (3% of any stray ETH it forwards) |

Read the deployed addresses from the launch contract: `pool()`, `hook()` and `salt()`.

## After the launch (the owner)

The coin is launched by the swarm's Pons launcher (launch #1026, `0xE0aBb21F15766BE162429f46F494617eB5EF6Ba0`,
magic0xfrens/imd6900-pons-launch), at `0x69005D86d2c1bb1dFE70Df48e27D6aa02D044149`. Its `launch(salt, coin, 2 ether,
minOut)` dev-buys with 2 ETH of what the old IMDSTR pool's pull sent it and refunds the rest to the team wallet. That
refund opens this pool. `script/Owner.s.sol` runs the steps from the team wallet:

1. `open(<pool>, <wei>)`: releases from the launcher the coin worth `<wei>` at the Pons curve's price (the coin beyond
   one per IMDSTR, which no holder can claim), and opens the pool at that price with the ETH.
2. `wire(<pool>)`: the coin's creator fees split 70% pot bridge, 10% this pool (its `compound` turns them into depth),
   20% the team; the pool's fee sink is the launcher.
3. Deploy the perps engine and its vault against the open pool, then `hook.setPerpEngine(engine)` and
   `pool.setPerpEngine(engine)`.
4. Hand both to the Robinhood timelock using the two-step handover on **each** contract: the timelock calls
   `requestOwnershipHandover()`, then the current owner calls `completeOwnershipHandover(timelock)` within 48 hours.
   Verify both `owner()` values. The one-step `transferOwnership` remains available; `NoRenounce` does not protect
   against transferring to an incorrect or unusable nonzero address.

**The liquidity always comes back.** The pool contract owns all of it and its owner can take it all out with
`removeLiquidity`; the hook only checks that the caller is the pool and the range is full, so no hook state can stop
it. The one guard is the pool's own engine check (no withdrawal that leaves an open position liquidatable), which the
owner can switch off with `pool.setPerpEngine(address(0))`. The hook is not upgradeable on purpose: a proxy needs
DELEGATECALL, which IMD's admission refuses, and an upgradeable hook would let one key change everyone's trading rules.
A new hook is a new launch: settle and close every engine position first, unwire the old engine on both contracts,
then take the liquidity out and open the new pool with it. A zero-liquidity pool's price can move within the band
without exchanging assets, so an engine must not keep using it as a mark. Disabling the withdrawal check alone is
not a safe migration for live positions.

`test/RobinhoodFlow.fork.t.sol` (needs `ROBINHOOD_RPC_URL`) runs all of it on live Robinhood state: the launcher's
2 ETH dev buy (525.7M coins, 0.8283 ETH refunded, 205.6M releasable), this launch as the swarm deploys it, the pool
opened at the Pons price, trades through the hook and the band, the fee split feeding the pool, the owner taking all
the liquidity back past a blocking and a broken engine, and a second hook opened with the same money. Pons taxes buys
in the coin's launch block ~99% (anti-sniper; the launcher's own buy is exempt), 6.9% after.

## The IMD swarm's audit (job ea1c84c3), fixed

The swarm's five auditors found four medium and several low issues; every one is fixed and held by
`test/AuditFixes.t.sol`:

- `compound()` pairs the pool's idle funds only within 1% of the Pons price (`COMPOUND_MAX_DEV_BPS`): it can't be
  sandwiched by a caller who just pushed the price.
- The pre-trade sweep fails closed at any gas: a down engine at low gas reverts `SweepUnavailable` (unless the owner
  sets fail-open), as it does at normal gas.
- The band is judged on the price the trader left, read before the post-trade sweep (an engine's nested swap can't
  hide a push, and its liquidations aren't rolled back by the band); "closer" means closer on the same side, so no swap
  can cross the Pons price and end out of band on the other side; a price the band can't express reads as off scale.
- The whole Pons read sits behind one try: an unreadable reference turns the band off, never halts trading; the owner
  can repoint the curve (`pool.setCurve`).
- No zero fee address, no zero curve or coin at `open`, a fee sink must be a contract, ownership can't be renounced
  (it would strand the liquidity), ETH goes out with plain transfers (no forced-send forwarder), an addition reports its
  principal (the fees the position earned stay in the pool), and a price outside the full range is `ZeroLiquidity`.
- The dead skim setting is gone: `setBand(maxDeviationBps)`.

The swarm's second pass (job d07ab5c6 and the import audit of this relaunch) found two medium and two low issues;
every one is fixed and held by `test/AuditFixes.t.sol` too (`ADAPTATION.md` has each finding, its reproduction and
its fix):

- `compound()` and `addLiquidity()` both run only within 1% of the Pons price (`COMPOUND_MAX_DEV_BPS`) and never
  without one: a reference the hook cannot read is `NoPonsReference`, not "on price". Either could be sandwiched
  before: a push inside the 30% band, the pairing at that price, a sell-back into the depth it added.
- The hook's constructor refuses a zero fee address (as `updateFeeAddress` already did): `flush()` would have burnt
  its 3%.
- `feeBps` and `perpFeeBps`, what the engine model reads as the pool's fee, are derived from `poolFeePips` at
  construction (100 bps for this launch's 1%) instead of starting at 10%.
- The ten `Ownable` entry points the hook and the pool inherit from solady (transfer, renounce, request / cancel /
  complete handover) and the owner's right to take all the liquidity back whatever the hook's state are tested
  explicitly.

## Admission (what IMD checks, and the tests that check it first)

`forge test`, offline, no RPC:

- `test_DeploysOnAFreshChain`: the launch deploys where nothing it names exists (IMD deploys a launch on a fresh chain
  first); the hook's address carries its flags, the pool and the hook name each other, both are the owner's.
- `test_FitsOneTransaction` uses raw CREATE and requires a metered cost above 3M. `test/LaunchAdmission.t.sol` also
  uses raw CREATE2, includes calldata/intrinsic gas and factory headroom, and tests 24 factory salts plus the reported
  salt 50149. A fixed address/hash retains the original 132,475-attempt regression even when launch bytecode changes.
  The miner now tests eight salts per batch (~90 gas/attempt) and stops after 134,144 attempts with `NoSalt`.
  Exhaustion costs about 12.03M gas for mining; the gas-budget test accounts for deploying and wiring the contracts.
- `test_EachDeployerMinesItsOwnSalt`: whatever address deploys it, it finds its own salt.
- `test_PassesTheAdmissionScan`: no contract's code shows CALLCODE, DELEGATECALL or SELFDESTRUCT (PUSH data skipped).
- `test_RefusesADynamicFee`: a dynamic fee would cost the pool Uniswap's automatic routing; the hook refuses it.
- `test/IMD6900Perps.t.sol`, against a real v4 PoolManager (vendored, tests only): the pool opens at the Pons price,
  trades both ways, refuses a trade that would leave it more than 30% from Pons, refuses anyone else's liquidity, only
  the owner opens it and takes liquidity out, anyone deepens it, and perps stay off until an engine is set.

### Rehearse the actual factory deployment

Salt search is probabilistic across addresses, deterministic for a particular launch. No finite transaction can
promise a matching hash for every possible deployer. The bounded search misses roughly one address in 3,600 under
uniform hashing. An average or a sample is not admission for the actual launch.

Before admission, supply the real `IMD_PROJECT_FACTORY` and `IMD_PROJECT_SALT_0` (the factory's resolved CREATE2 salt)
and run `forge test --offline --match-test test_ActualFactorySaltWhenProvided -vv`. This local rehearsal uses the
exact constructor arguments above and the current compiled init code at that factory address. It skips when the
factory is not supplied; it does not invent a production factory or launch number. The deployment service must also
simulate its complete transaction with its own wrapper overhead and total gas limit at or below 16,777,216.

On `NoSalt` or an over-budget simulation, do not broadcast or retry the identical bytes with a higher gas limit.
Request a new launch number from the launch service, derive its new factory salt/address, and repeat admission and
simulation. The four constructor arguments and hook permission flags stay unchanged. This worker neither signs nor
broadcasts transactions.

### Fee accounting and owner trust

- The pool charges its immutable 1% on every swap. `feeFor`, `feeBps` and `perpFeeBps` report that same rate (100 bps).
  `feeExempt` exempts only from the Pons band. The legacy `lowerFee` entry point always refuses a change;
  `setPerpFeeBps` accepts only the actual pool rate. Neither changes swap accounting or the 97%/3% stray-ETH split.
- `compound` pairs idle balances. If either currency is missing, it first collects earned fees from a non-empty
  position. If no matching coin exists even then, the owner must supply coin before compounding. `removeLiquidity`
  returns position principal and earned fees, not unrelated idle balances. To recover unmatched idle ETH, send the
  matching coin, compound while on Pons, then remove the resulting liquidity. The hook does not skim coin.
- The band uses `abs(poolCoinPerEth - ponsCoinPerEth) / ponsCoinPerEth`, rounded down to basis points. The default
  30% band therefore spans roughly -23.08% to +42.86% in the reciprocal ETH-per-coin price. It is not a symmetric
  ETH-per-coin limit; the future engine must use the documented units and assess the mark's liquidity.
- `open` now enforces the same readable-reference/1% guard as additions and compounding. If the Pons price changed
  since script simulation, opening reverts atomically; recompute the quote and retry.
- The owner can redirect the fee address before a flush (including ETH already received), renounce that share to
  the pool, change band exemptions and width, repoint the curve, replace or disable either engine, and enable
  fail-open sweeping. A hook engine without compatible code blocks ordinary swaps until repaired or fail-open is
  enabled. Hook and pool ownership and engine settings are independent and must be checked separately.
- A fee sink must implement payable `addFees()`. Code presence alone does not establish compatibility. A reverting
  sink leaves the hook's balance intact; the owner can use `setFeeSink(address(0))` to retain subsequent flushes in
  the pool, or configure a working sink. The fork flow now calls `flush` through the actual configured Pons launcher
  and checks its split. That integration remains unverified until the fork suite is run with `ROBINHOOD_RPC_URL`.

Every library is vendored under `lib/` (only the files imported), so it builds offline: see `lib/README.md`.
