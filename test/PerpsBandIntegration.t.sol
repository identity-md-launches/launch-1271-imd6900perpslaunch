// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IMD6900PerpHook} from "src/IMD6900PerpHook.sol";
import {Coin} from "./IMD6900Perps.t.sol";
import {PerpsTestFixture} from "./helpers/PerpsTestFixture.sol";

/// Liquidation can trade recursively during a hook callback while the manager is already unlocked.
contract NestedSweepEngine {
    IPoolManager immutable manager;
    Coin immutable coin;
    PoolKey internal key;
    uint256 public postCalls;
    uint256 public openCount;
    uint256 public sellAmount = 10 ether;

    constructor(IPoolManager m, Coin c, PoolKey memory k) {
        manager = m;
        coin = c;
        key = k;
    }

    function setSellAmount(uint256 amount) external {
        sellAmount = amount;
    }

    function sweepLiquidations(address, int256 spec, bool, uint160) external returns (uint8) {
        require(msg.sender == address(key.hooks), "only hook");
        if (spec != 0) return 0;
        ++postCalls;
        BalanceDelta delta = manager.swap(key, SwapParams(false, -int256(sellAmount), TickMath.MAX_SQRT_PRICE - 1), "");
        manager.sync(key.currency1);
        coin.transfer(address(manager), uint128(-delta.amount1()));
        manager.settle();
        manager.take(Currency.wrap(address(0)), address(this), uint128(delta.amount0()));
        return 0;
    }
    receive() external payable {}
}

contract PerpsBandIntegrationTest is PerpsTestFixture {
    function _bandError() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hook.afterSwap.selector,
            abi.encodeWithSelector(IMD6900PerpHook.TooFarFromPons.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function test_BandRejectionRollsBackBothCurrenciesAndPrice() public {
        uint256 ethBefore = address(router).balance;
        uint256 coinBefore = coin.balanceOf(address(router));
        uint256 priceBefore = hook.poolPriceX96();
        vm.expectRevert(_bandError());
        router.swap(key, true, -30 ether);
        assertEq(address(router).balance, ethBefore);
        assertEq(coin.balanceOf(address(router)), coinBefore);
        assertEq(hook.poolPriceX96(), priceBefore);
        vm.expectRevert(_bandError());
        router.swap(key, false, -30 ether);
        assertEq(hook.poolPriceX96(), priceBefore);
        assertEq(address(router).balance, ethBefore);
        assertEq(coin.balanceOf(address(router)), coinBefore);
    }

    function test_SellCanCorrectBelowPonsButCannotCrossAndFinishOutOfBand() public {
        referenceCurve.set(1 ether, 2 ether);
        uint256 before = hook.deviationBps();
        assertEq(before, 5000);
        router.swap(key, false, -10 ether);
        assertLt(hook.deviationBps(), before);
        assertGt(hook.deviationBps(), hook.maxDeviationBps(), "corrections may remain outside the band");
        vm.expectRevert(_bandError());
        router.swap(key, false, -100 ether);
    }

    function test_ExemptionChangesBandOnlyAndCanBeRevoked() public {
        vm.prank(TEAM);
        hook.setFeeExempt(address(router), true);
        assertFalse(hook.tracksPons(address(router)));
        assertEq(hook.feeFor(address(router)), 100);
        router.swap(key, true, -30 ether);
        assertGt(hook.deviationBps(), 3000);
        vm.prank(TEAM);
        hook.setFeeExempt(address(router), false);
        assertTrue(hook.tracksPons(address(router)));
        vm.expectRevert(_bandError());
        router.swap(key, true, -1 ether); // pushes an already displaced pool farther away
        uint256 before = hook.deviationBps();
        router.swap(key, false, -1 ether);
        assertLt(hook.deviationBps(), before);
    }

    function test_PostSweepCannotHideAnOutOfBandTrade() public {
        NestedSweepEngine e = new NestedSweepEngine(manager, coin, key);
        coin.mint(address(e), 1000 ether);
        vm.prank(TEAM);
        hook.setPerpEngine(address(e));
        // The nested 10-coin sell would repair the 30-ETH buy into the band. The trader's own
        // final price must be checked before that nested swap overwrites the transient start value.
        vm.expectRevert(_bandError());
        router.swap(key, true, -30 ether);
        assertEq(e.postCalls(), 0);
        assertEq(hook.poolPriceX96(), Q96);
        // Prove the fixture really can do the recursive swap, rather than passing on a broken engine.
        vm.prank(TEAM);
        hook.setFeeExempt(address(router), true);
        router.swap(key, true, -30 ether);
        assertEq(e.postCalls(), 1);
        assertLt(hook.deviationBps(), 3000);
    }

    function test_LiquidationAfterAValidTradeIsNotRolledBackByTheBand() public {
        NestedSweepEngine e = new NestedSweepEngine(manager, coin, key);
        e.setSellAmount(30 ether);
        coin.mint(address(e), 1000 ether);
        vm.prank(TEAM);
        hook.setPerpEngine(address(e));
        router.swap(key, true, -0.01 ether); // ordinary trade is inside the band
        assertEq(e.postCalls(), 1);
        assertGt(hook.deviationBps(), 3000, "engine liquidation itself is deliberately exempt");
        assertGt(address(e).balance, 0, "nested settlement actually completed");
    }
}
