// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IMD6900PerpPool} from "src/IMD6900PerpPool.sol";
import {IMD6900PerpHook} from "src/IMD6900PerpHook.sol";
import {Coin, Trader} from "./IMD6900Perps.t.sol";
import {MovableCurve} from "./AuditFixes.t.sol";
import {PerpsTestFixture} from "./helpers/PerpsTestFixture.sol";

contract LiquiditySequenceHandler is Test {
    IMD6900PerpPool public immutable pool;
    IMD6900PerpHook public immutable hook;
    Coin public immutable coin;
    MovableCurve public immutable curve;
    Trader public immutable router;
    address public immutable owner;
    address public immutable manager;
    address[3] public actors;
    uint256 public ethIn;
    uint256 public ethOut;
    uint256 public coinIn;
    uint256 public coinOut;
    uint256 public additions;
    uint256 public removals;
    uint256 public compounds;
    uint256 public swaps;
    uint256 public emptyCompounds;
    uint256 public rejectedCalls;

    constructor(IMD6900PerpPool p, IMD6900PerpHook h, Coin c, MovableCurve ref, Trader r) {
        pool = p;
        hook = h;
        coin = c;
        curve = ref;
        router = r;
        owner = p.owner();
        manager = address(p.poolManager());
        ethIn = manager.balance + address(p).balance;
        coinIn = c.balanceOf(manager) + c.balanceOf(address(p));
        for (uint256 i; i < 3; ++i) {
            address actor = address(uint160(0x1001 + i));
            actors[i] = actor;
            vm.deal(actor, 1000 ether);
            c.mint(actor, 1000 ether);
            vm.prank(actor);
            c.approve(address(p), type(uint256).max);
        }
    }

    // These are external-market movements, not a mock of the hook's deviation calculation.
    function _align() internal {
        curve.set(1 << 96, hook.poolPriceX96());
    }

    function add(uint256 actorSeed, uint256 ethSeed, uint256 coinSeed) public {
        address payer = actors[actorSeed % 3];
        address refund = actors[(actorSeed % 3 + 1) % 3];
        uint256 eth = bound(ethSeed, 1e6, 1 ether);
        uint256 tokens = bound(coinSeed, 1e6, 1 ether);
        _align();
        uint256 beforeEth = payer.balance + refund.balance;
        uint256 beforeCoin = coin.balanceOf(payer) + coin.balanceOf(refund);
        uint128 beforeL = pool.liquidity();
        vm.prank(payer);
        pool.addLiquidity{value: eth}(tokens, refund);
        uint256 spentEth = beforeEth - payer.balance - refund.balance;
        uint256 spentCoin = beforeCoin - coin.balanceOf(payer) - coin.balanceOf(refund);
        assertLe(spentEth, eth, "an addition cannot charge more than supplied");
        assertLe(spentCoin, tokens);
        assertGt(spentEth, 0);
        assertGt(spentCoin, 0);
        assertGt(pool.liquidity(), beforeL);
        ethIn += spentEth;
        coinIn += spentCoin;
        ++additions;
    }

    function donate(uint256 actorSeed, uint256 ethSeed, uint256 coinSeed) public {
        address actor = actors[actorSeed % 3];
        uint256 eth = bound(ethSeed, 0, 1 ether);
        uint256 tokens = bound(coinSeed, 0, 1 ether);
        vm.startPrank(actor);
        (bool ok,) = address(pool).call{value: eth}("");
        assertTrue(ok);
        coin.transfer(address(pool), tokens);
        vm.stopPrank();
        ethIn += eth;
        coinIn += tokens;
    }

    function compound(uint256 actorSeed) external {
        _align();
        address actor = actors[actorSeed % 3];
        uint256 eth = actor.balance;
        uint256 tokens = coin.balanceOf(actor);
        uint128 beforeL = pool.liquidity();
        vm.prank(actor);
        (bool ok, bytes memory result) = address(pool).call(abi.encodeCall(pool.compound, (0, 0)));
        if (ok) {
            uint128 added = abi.decode(result, (uint128));
            assertGt(added, 0);
            assertEq(pool.liquidity(), uint256(beforeL) + added);
            ++compounds;
        } else {
            // No idle or earned matching asset is a documented, specific failure, not a swallowed revert.
            assertEq(result, abi.encodeWithSelector(IMD6900PerpPool.ZeroLiquidity.selector));
            assertEq(pool.liquidity(), beforeL);
            ++emptyCompounds;
        }
        assertEq(actor.balance, eth, "compound must not reward its caller with protocol ETH");
        assertEq(coin.balanceOf(actor), tokens, "compound must not refund earned coin fees");
    }

    function swap(uint256 amountSeed, bool buy, bool exactOutput) external {
        if (pool.liquidity() < 1e12) add(0, 1 ether, 1 ether);
        _align();
        uint256 reserve = (buy != exactOutput) ? manager.balance : coin.balanceOf(manager);
        uint256 maximum = reserve / 200;
        if (maximum > 1 ether) maximum = 1 ether;
        assertGt(maximum, 0);
        uint256 amount = bound(amountSeed, 1, maximum);
        int256 specified = exactOutput ? int256(amount) : -int256(amount);
        uint256 eth = address(router).balance;
        uint256 tokens = coin.balanceOf(address(router));
        uint128 beforeL = pool.liquidity();
        BalanceDelta delta = router.swap(pool.poolKey(), buy, specified);
        assertEq(pool.liquidity(), beforeL, "a swap cannot create or destroy the position");
        if (buy) {
            uint256 paid = eth - address(router).balance;
            uint256 received = coin.balanceOf(address(router)) - tokens;
            assertEq(paid, uint256(uint128(-delta.amount0())));
            assertEq(received, uint256(uint128(delta.amount1())));
            assertEq(exactOutput ? received : paid, amount);
            ethIn += paid;
            coinOut += received;
        } else {
            uint256 paid = tokens - coin.balanceOf(address(router));
            uint256 received = address(router).balance - eth;
            assertEq(paid, uint256(uint128(-delta.amount1())));
            assertEq(received, uint256(uint128(delta.amount0())));
            assertEq(exactOutput ? received : paid, amount);
            coinIn += paid;
            ethOut += received;
        }
        ++swaps;
    }

    function remove(uint256 amountSeed, uint256 recipientSeed, bool all) external {
        uint128 liq = pool.liquidity();
        if (liq == 0) add(0, 1 ether, 1 ether);
        liq = pool.liquidity();
        uint128 amount = all ? liq : uint128(bound(amountSeed, 1, liq));
        address ethTo = actors[recipientSeed % 3];
        address coinTo = actors[(recipientSeed % 3 + 1) % 3];
        uint256 eth = ethTo.balance;
        uint256 tokens = coin.balanceOf(coinTo);
        vm.prank(owner);
        pool.removeLiquidity(amount, ethTo, coinTo);
        assertEq(pool.liquidity(), liq - amount);
        ethOut += ethTo.balance - eth;
        coinOut += coin.balanceOf(coinTo) - tokens;
        ++removals;
    }

    function unauthorizedRemoval(uint256 actorSeed, uint128 amount) external {
        address actor = actors[actorSeed % 3];
        uint128 liq = pool.liquidity();
        vm.prank(actor);
        (bool ok, bytes memory result) =
            address(pool).call(abi.encodeCall(pool.removeLiquidity, (amount, actor, actor)));
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(Ownable.Unauthorized.selector));
        assertEq(pool.liquidity(), liq);
        ++rejectedCalls;
    }

    function referenceUnavailable(uint256 actorSeed) external {
        curve.set(0, 0);
        vm.prank(actors[actorSeed % 3]);
        (bool ok, bytes memory result) = address(pool).call(abi.encodeCall(pool.compound, (0, 0)));
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(IMD6900PerpPool.NoPonsReference.selector));
        ++rejectedCalls;
        // Leave the unavailable reference in place: the withdrawal invariant must still work.
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PerpsLiquidityInvariantTest is PerpsTestFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    LiquiditySequenceHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LiquiditySequenceHandler(pool, hook, coin, referenceCurve, router);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.add.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.compound.selector;
        selectors[3] = handler.swap.selector;
        selectors[4] = handler.remove.selector;
        selectors[5] = handler.unauthorizedRemoval.selector;
        selectors[6] = handler.referenceUnavailable.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_assetsMatchExternalCashFlows() public view {
        assertEq(
            address(manager).balance + address(pool).balance + handler.ethOut(),
            handler.ethIn(),
            "ETH must equal external contributions less distributions"
        );
        assertEq(
            coin.balanceOf(address(manager)) + coin.balanceOf(address(pool)) + handler.coinOut(),
            handler.coinIn(),
            "coin must equal external contributions less distributions"
        );
        (uint128 position,,) = manager.getPositionInfo(
            key.toId(), address(pool), TickMath.minUsableTick(60), TickMath.maxUsableTick(60), bytes32(0)
        );
        assertEq(position, pool.liquidity(), "all active liquidity belongs to the pool's full-range position");
        assertEq(pool.owner(), TEAM);
        assertEq(hook.owner(), TEAM);
        assertEq(hook.feeFor(address(router)), 100);
    }

    function invariant_ownerCanWithdrawTheEntirePosition() public {
        uint256 snapshot = vm.snapshotState();
        uint128 liq = pool.liquidity();
        if (liq != 0) {
            (uint160 price,,,) = manager.getSlot0(key.toId());
            uint256 principalEth = SqrtPriceMath.getAmount0Delta(
                price, TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(60)), liq, false
            );
            uint256 principalCoin = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(60)), price, liq, false
            );
            uint256 ethBefore = TEAM.balance;
            uint256 coinBefore = coin.balanceOf(TEAM);
            vm.prank(TEAM);
            pool.removeLiquidity(liq, TEAM, TEAM);
            assertEq(pool.liquidity(), 0);
            assertGe(TEAM.balance - ethBefore, principalEth, "full withdrawal returns at least all native principal");
            assertGe(
                coin.balanceOf(TEAM) - coinBefore, principalCoin, "full withdrawal returns at least all coin principal"
            );
        }
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    /// Deterministic reachability check complements the fuzzer's per-selector call/revert statistics.
    function test_HandlerExercisesAnEntireLifecycle() public {
        handler.swap(0.01 ether, true, false);
        handler.swap(0.01 ether, false, true);
        handler.add(1, 1 ether, 0.5 ether);
        handler.donate(2, 0.5 ether, 1 ether);
        handler.compound(0);
        handler.unauthorizedRemoval(1, 1);
        handler.referenceUnavailable(2);
        invariant_assetsMatchExternalCashFlows();
        invariant_ownerCanWithdrawTheEntirePosition();
        handler.remove(0, 1, true);
        handler.add(2, 1 ether, 1 ether);
        assertEq(handler.swaps(), 2);
        assertEq(handler.additions(), 2);
        assertEq(handler.compounds(), 1);
        assertEq(handler.removals(), 1);
        assertEq(handler.rejectedCalls(), 2);
        invariant_assetsMatchExternalCashFlows();
    }
}
