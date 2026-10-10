// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IMD6900PerpsLaunch} from "src/IMD6900PerpsLaunch.sol";
import {IMD6900PerpHook} from "src/IMD6900PerpHook.sol";
import {IMD6900PerpPool} from "src/IMD6900PerpPool.sol";
import {PerpsTestFixture, SweepAndBookDouble} from "./helpers/PerpsTestFixture.sol";

contract ShortEngineResponse {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0)
            return(0, 31)
        }
    }
}

contract RejectingReceiver {
    receive() external payable {
        revert("no ETH");
    }
}

contract ReenteringRefundReceiver {
    IMD6900PerpPool immutable pool;
    bool public attempted;
    bytes public reason;

    constructor(IMD6900PerpPool p) {
        pool = p;
    }

    receive() external payable {
        attempted = true;
        (bool ok, bytes memory result) = address(pool).call(abi.encodeCall(pool.compound, (0, 0)));
        require(!ok, "reentrant compound succeeded");
        reason = result;
    }
}

contract PerpsFailurePathsTest is PerpsTestFixture {
    using PoolIdLibrary for PoolKey;

    function _params() internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1, bytes32(0));
    }

    function _swapParams() internal pure returns (SwapParams memory) {
        return SwapParams(true, -0.01 ether, TickMath.MIN_SQRT_PRICE + 1);
    }

    function _engine() internal returns (SweepAndBookDouble e) {
        e = new SweepAndBookDouble();
        vm.prank(TEAM);
        hook.setPerpEngine(address(e));
    }

    function _before(address sender, uint256 gasBudget) internal returns (bytes4, BeforeSwapDelta, uint24) {
        vm.prank(address(manager));
        return hook.beforeSwap{gas: gasBudget}(sender, key, _swapParams(), "");
    }

    function test_AllHookCallbacksAuthenticateTheManager() public {
        bytes[] memory calls = new bytes[](10);
        ModifyLiquidityParams memory p = _params();
        SwapParams memory s = _swapParams();
        BalanceDelta zero = BalanceDelta.wrap(0);
        calls[0] = abi.encodeCall(hook.beforeInitialize, (address(pool), key, Q96));
        calls[1] = abi.encodeCall(hook.afterInitialize, (address(pool), key, Q96, int24(0)));
        calls[2] = abi.encodeCall(hook.beforeAddLiquidity, (address(pool), key, p, ""));
        calls[3] = abi.encodeCall(hook.afterAddLiquidity, (address(pool), key, p, zero, zero, ""));
        calls[4] = abi.encodeCall(hook.beforeRemoveLiquidity, (address(pool), key, p, ""));
        calls[5] = abi.encodeCall(hook.afterRemoveLiquidity, (address(pool), key, p, zero, zero, ""));
        calls[6] = abi.encodeCall(hook.beforeSwap, (address(router), key, s, ""));
        calls[7] = abi.encodeCall(hook.afterSwap, (address(router), key, s, zero, ""));
        calls[8] = abi.encodeCall(hook.beforeDonate, (address(pool), key, 1, 1, ""));
        calls[9] = abi.encodeCall(hook.afterDonate, (address(pool), key, 1, 1, ""));
        for (uint256 i; i < calls.length; ++i) {
            _expectCallError(address(hook), address(this), calls[i], ImmutableState.NotPoolManager.selector);
            // Correct sender arguments cannot replace the manager's authentication.
            _expectCallError(address(hook), TEAM, calls[i], ImmutableState.NotPoolManager.selector);
        }
        uint256[5] memory disabled = [uint256(1), 3, 5, 8, 9];
        for (uint256 i; i < disabled.length; ++i) {
            _expectCallError(address(hook), address(manager), calls[disabled[i]], BaseHook.HookNotImplemented.selector);
        }
    }

    function test_InitializationRejectsForeignSenderAndWrongKeyThenIsOneShot() public {
        IMD6900PerpsLaunch fresh = new IMD6900PerpsLaunch(manager, 10000, TEAM, TEAM);
        IMD6900PerpPool p = fresh.pool();
        IMD6900PerpHook h = fresh.hook();
        PoolKey memory correct = p.poolKey();
        // Before open(), token() is zero. Manager impersonation isolates the key guard; actual opening is
        // exercised with the real manager in every fixture and in the atomic-opening tests below.
        _expectCallError(
            address(h),
            address(manager),
            abi.encodeCall(h.beforeInitialize, (TEAM, correct, Q96)),
            IMD6900PerpHook.OnlyLauncher.selector
        );
        for (uint256 i; i < 5; ++i) {
            PoolKey memory wrong = p.poolKey();
            if (i == 0) wrong.currency0 = Currency.wrap(address(coin));
            if (i == 1) wrong.currency1 = Currency.wrap(address(coin));
            if (i == 2) wrong.fee = 3000;
            if (i == 3) wrong.fee = 0x800000;
            if (i == 4) wrong.tickSpacing = 1;
            _expectCallError(
                address(h),
                address(manager),
                abi.encodeCall(h.beforeInitialize, (address(p), wrong, Q96)),
                IMD6900PerpHook.NotOurPool.selector
            );
            assertEq(PoolId.unwrap(h.poolId()), bytes32(0));
        }
        vm.startPrank(TEAM);
        coin.approve(address(p), type(uint256).max);
        p.open{value: 1 ether}(address(coin), address(referenceCurve), Q96, 1 ether);
        vm.stopPrank();
        correct = p.poolKey();
        assertEq(PoolId.unwrap(h.poolId()), PoolId.unwrap(correct.toId()));
        _expectCallError(
            address(h),
            address(manager),
            abi.encodeCall(h.beforeInitialize, (address(p), correct, Q96)),
            IMD6900PerpHook.NotOurPool.selector
        );
    }

    function test_LiquidityCallbacksRequirePoolAndBothFullRangeBounds() public {
        for (uint256 remove; remove < 2; ++remove) {
            bytes4 selector = remove == 0 ? hook.beforeAddLiquidity.selector : hook.beforeRemoveLiquidity.selector;
            ModifyLiquidityParams memory p = _params();
            _expectCallError(
                address(hook),
                address(manager),
                abi.encodeWithSelector(selector, TEAM, key, p, bytes("")),
                IMD6900PerpHook.OnlyLauncher.selector
            );
            p.tickLower += 60;
            _expectCallError(
                address(hook),
                address(manager),
                abi.encodeWithSelector(selector, address(pool), key, p, bytes("")),
                IMD6900PerpHook.FullRangeOnly.selector
            );
            p = _params();
            p.tickUpper -= 60;
            _expectCallError(
                address(hook),
                address(manager),
                abi.encodeWithSelector(selector, address(pool), key, p, bytes("")),
                IMD6900PerpHook.FullRangeOnly.selector
            );
            p = _params();
            vm.prank(address(manager));
            (bool ok, bytes memory result) =
                address(hook).call(abi.encodeWithSelector(selector, address(pool), key, p, bytes("")));
            assertTrue(ok);
            assertEq(abi.decode(result, (bytes4)), selector);
        }
    }

    function test_SweepParametersZeroDeltasAndBestEffortPostSweep() public {
        SweepAndBookDouble e = _engine();
        (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride) = _before(address(router), 2_000_000);
        assertEq(selector, hook.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(feeOverride, 0);
        assertEq(e.calls(), 1);
        assertEq(e.lastLiquidator(), tx.origin);
        assertEq(e.lastSpec(), -0.01 ether);
        assertTrue(e.lastBuy());
        assertEq(e.lastLimit(), TickMath.MIN_SQRT_PRICE + 1);
        int128 afterDelta;
        vm.prank(address(manager));
        (selector, afterDelta) = hook.afterSwap(address(router), key, _swapParams(), BalanceDelta.wrap(0), "");
        assertEq(selector, hook.afterSwap.selector);
        assertEq(afterDelta, 0);
        assertEq(e.calls(), 2);
        assertEq(e.lastSpec(), 0);
        assertFalse(e.lastBuy());
        assertEq(e.lastLimit(), 0);
        e.configure(0, 1, true, false);
        vm.prank(address(manager));
        hook.afterSwap(address(router), key, _swapParams(), BalanceDelta.wrap(0), "");
        assertEq(e.calls(), 2, "a reverted best-effort sweep is not a failed swap");
    }

    function test_SweepStatusCannotBeBypassedByFailOpen() public {
        SweepAndBookDouble e = _engine();
        for (uint256 failOpen; failOpen < 2; ++failOpen) {
            vm.prank(TEAM);
            hook.setSweepFailOpen(failOpen != 0);
            e.configure(2, 1, false, false);
            vm.expectRevert(IMD6900PerpHook.SweepTradeTooLarge.selector);
            _before(address(router), 2_000_000);
            e.configure(1, 1, false, false);
            vm.expectRevert(IMD6900PerpHook.SweepGasStarved.selector);
            _before(address(router), 2_000_000);
            e.configure(type(uint256).max, 1, false, false);
            vm.expectRevert(IMD6900PerpHook.SweepGasStarved.selector);
            _before(address(router), 2_000_000);
        }
    }

    function test_SweepAvailabilityLowGasAndEngineSelfSwap() public {
        SweepAndBookDouble e = _engine();
        e.configure(0, 1, true, false);
        vm.expectRevert(IMD6900PerpHook.SweepUnavailable.selector);
        _before(address(router), 2_000_000);
        vm.prank(TEAM);
        hook.setSweepFailOpen(true);
        _before(address(router), 2_000_000);
        // A readable openCount > 0 fails closed even when fail-open is on.
        vm.expectRevert(IMD6900PerpHook.SweepGasStarved.selector);
        _before(address(router), 600_000);
        e.configure(0, 0, true, false);
        _before(address(router), 600_000);
        _before(address(e), 600_000);
        assertEq(e.calls(), 0, "low-gas empty book and engine's own swap skip sweeping");
        assertFalse(hook.tracksPons(address(e)));
        assertEq(hook.feeFor(address(e)), 100);
    }

    function test_MalformedSweepAndOpenCountFailClosedAtBothGasBudgets() public {
        address malformed = address(new ShortEngineResponse());
        vm.prank(TEAM);
        hook.setPerpEngine(malformed);
        vm.expectRevert(IMD6900PerpHook.SweepUnavailable.selector);
        _before(address(router), 2_000_000);
        vm.expectRevert(IMD6900PerpHook.SweepUnavailable.selector);
        _before(address(router), 600_000);
        vm.prank(TEAM);
        hook.setSweepFailOpen(true);
        _before(address(router), 2_000_000);
        _before(address(router), 600_000);
    }

    function test_SwapRejectsForeignPoolBeforeCallingTheEngine() public {
        SweepAndBookDouble e = _engine();
        PoolKey memory wrong = pool.poolKey();
        wrong.fee = 3000;
        _expectCallError(
            address(hook),
            address(manager),
            abi.encodeCall(hook.beforeSwap, (address(router), wrong, _swapParams(), "")),
            IMD6900PerpHook.NotOurPool.selector
        );
        assertEq(e.calls(), 0);
    }

    function test_AllAdministrativeMutationsRejectNonOwners() public {
        bytes[] memory hookCalls = new bytes[](10);
        hookCalls[0] = abi.encodeCall(hook.lowerFee, (100));
        hookCalls[1] = abi.encodeCall(hook.setPerpFeeBps, (100));
        hookCalls[2] = abi.encodeCall(hook.setPerpEngine, (address(router)));
        hookCalls[3] = abi.encodeCall(hook.setSweepFailOpen, (true));
        hookCalls[4] = abi.encodeCall(hook.setBand, (1));
        hookCalls[5] = abi.encodeCall(hook.setFeeExempt, (address(this), true));
        hookCalls[6] = abi.encodeCall(hook.updateFeeAddress, (address(this)));
        hookCalls[7] = abi.encodeCall(hook.renounceOwnership, ());
        hookCalls[8] = abi.encodeCall(hook.transferOwnership, (address(this)));
        hookCalls[9] = abi.encodeCall(hook.completeOwnershipHandover, (address(this)));
        bytes[] memory poolCalls = new bytes[](9);
        poolCalls[0] = abi.encodeCall(pool.setHook, (address(this)));
        poolCalls[1] = abi.encodeCall(pool.setFeeSink, (address(0)));
        poolCalls[2] = abi.encodeCall(pool.setPerpEngine, (address(router)));
        poolCalls[3] = abi.encodeCall(pool.setCurve, (address(referenceCurve)));
        poolCalls[4] = abi.encodeCall(pool.renounceOwnership, ());
        poolCalls[5] = abi.encodeCall(pool.transferOwnership, (address(this)));
        poolCalls[6] = abi.encodeCall(pool.completeOwnershipHandover, (address(this)));
        poolCalls[7] = abi.encodeCall(pool.open, (address(coin), address(referenceCurve), Q96, 0));
        poolCalls[8] = abi.encodeCall(pool.removeLiquidity, (1, address(this), address(this)));
        for (uint256 i; i < hookCalls.length; ++i) {
            _expectCallError(address(hook), address(this), hookCalls[i], Ownable.Unauthorized.selector);
        }
        for (uint256 i; i < poolCalls.length; ++i) {
            _expectCallError(address(pool), address(this), poolCalls[i], Ownable.Unauthorized.selector);
        }
        assertEq(hook.owner(), TEAM);
        assertEq(pool.owner(), TEAM);
    }

    function test_ClosedPoolAndZeroInputsHaveSpecificFailures() public {
        IMD6900PerpPool closed = new IMD6900PerpPool(manager, 10000, TEAM);
        vm.expectRevert(IMD6900PerpPool.NotOpen.selector);
        closed.addLiquidity(0, TEAM);
        vm.expectRevert(IMD6900PerpPool.NotOpen.selector);
        closed.compound(0, 0);
        vm.prank(TEAM);
        vm.expectRevert(IMD6900PerpPool.NoHook.selector);
        closed.open(address(coin), address(referenceCurve), Q96, 1);
        vm.prank(TEAM);
        vm.expectRevert(IMD6900PerpPool.HookAlreadySet.selector);
        pool.setHook(address(hook));
        vm.prank(TEAM);
        vm.expectRevert(IMD6900PerpPool.AlreadyOpen.selector);
        pool.open(address(coin), address(referenceCurve), Q96, 1);
        vm.prank(TEAM);
        vm.expectRevert(IMD6900PerpPool.ZeroLiquidity.selector);
        pool.removeLiquidity(0, TEAM, TEAM);
        vm.prank(TEAM);
        vm.expectRevert(IMD6900PerpPool.ZeroLiquidity.selector);
        pool.addLiquidity(0, TEAM);
        vm.prank(TEAM);
        vm.expectRevert(IMD6900PerpHook.InvalidBand.selector);
        hook.setBand(0);
        _expectCallError(
            address(pool),
            TEAM,
            abi.encodeCall(pool.unlockCallback, (abi.encode(int256(1)))),
            IMD6900PerpPool.OnlyPoolManager.selector
        );
    }

    function test_FailedOpeningRollsBackInitializationAndCanRetry() public {
        IMD6900PerpsLaunch fresh = new IMD6900PerpsLaunch(manager, 10000, TEAM, TEAM);
        IMD6900PerpPool p = fresh.pool();
        uint256 eth = TEAM.balance;
        uint256 tokens = coin.balanceOf(TEAM);
        vm.startPrank(TEAM);
        coin.approve(address(p), type(uint256).max);
        vm.expectRevert(IMD6900PerpPool.ZeroAddress.selector);
        p.open{value: 1 ether}(address(0), address(referenceCurve), Q96, 1 ether);
        vm.expectRevert(IMD6900PerpPool.ZeroLiquidity.selector);
        p.open{value: 1 ether}(address(coin), address(referenceCurve), Q96, 0);
        vm.expectRevert(IMD6900PerpPool.ZeroLiquidity.selector);
        p.open(address(coin), address(referenceCurve), Q96, 1 ether);
        vm.stopPrank();
        assertEq(p.token(), address(0));
        assertEq(p.curve(), address(0));
        assertEq(PoolId.unwrap(fresh.hook().poolId()), bytes32(0));
        assertEq(TEAM.balance, eth);
        assertEq(coin.balanceOf(TEAM), tokens);
        vm.prank(TEAM);
        p.open{value: 1 ether}(address(coin), address(referenceCurve), Q96, 1 ether);
        assertGt(p.liquidity(), 0);
    }

    function test_WithdrawalSafetyCheckIsAtomicAndOwnerCanRecoverFromBrokenBook() public {
        SweepAndBookDouble e = new SweepAndBookDouble();
        e.configure(0, 3, false, true);
        vm.prank(TEAM);
        pool.setPerpEngine(address(e));
        uint128 liq = pool.liquidity();
        uint256 eth = TEAM.balance;
        uint256 tokens = coin.balanceOf(TEAM);
        vm.prank(TEAM);
        vm.expectRevert(abi.encodeWithSelector(IMD6900PerpPool.WouldLiquidate.selector, uint256(1)));
        pool.removeLiquidity(liq, TEAM, TEAM);
        assertEq(pool.liquidity(), liq);
        assertEq(TEAM.balance, eth);
        assertEq(coin.balanceOf(TEAM), tokens);
        e.configure(0, 3, true, false);
        vm.prank(TEAM);
        vm.expectRevert(SweepAndBookDouble.EngineDown.selector);
        pool.removeLiquidity(liq, TEAM, TEAM);
        assertEq(pool.liquidity(), liq);
        // Hook policy and the external book cannot permanently trap the position.
        vm.startPrank(TEAM);
        hook.setBand(1);
        hook.setPerpEngine(address(e));
        pool.setPerpEngine(address(0));
        pool.removeLiquidity(liq, TEAM, TEAM);
        vm.stopPrank();
        assertEq(pool.liquidity(), 0);
        assertApproxEqAbs(TEAM.balance - eth, 100 ether, 2);
        assertApproxEqAbs(coin.balanceOf(TEAM) - tokens, 100 ether, 2);
    }

    function test_WithdrawalWithHealthyPositionsAndRejectingRecipient() public {
        SweepAndBookDouble e = new SweepAndBookDouble();
        e.configure(0, 3, false, false);
        vm.prank(TEAM);
        pool.setPerpEngine(address(e));
        address reject = address(new RejectingReceiver());
        uint128 liq = pool.liquidity();
        uint256 tokenBefore = coin.balanceOf(TEAM);
        vm.prank(TEAM);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        pool.removeLiquidity(liq, reject, TEAM);
        assertEq(pool.liquidity(), liq);
        assertEq(coin.balanceOf(TEAM), tokenBefore);
        vm.prank(TEAM);
        pool.removeLiquidity(liq, TEAM, TEAM);
        assertEq(pool.liquidity(), 0);
    }

    function test_RefundCallbackCannotReenterCompounding() public {
        ReenteringRefundReceiver receiver = new ReenteringRefundReceiver(pool);
        vm.prank(TEAM);
        pool.addLiquidity{value: 2 ether}(1 ether, address(receiver));
        assertTrue(receiver.attempted());
        assertEq(receiver.reason(), abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector));
        assertApproxEqAbs(address(receiver).balance, 1 ether, 1);
    }

    function test_FailedFeeRecipientRollsBackTheEarlierPoolPayment() public {
        address reject = address(new RejectingReceiver());
        vm.prank(TEAM);
        hook.updateFeeAddress(reject);
        vm.deal(address(hook), 1 ether);
        uint256 retained = address(pool).balance;
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        hook.flush();
        assertEq(address(pool).balance, retained, "97% payment must roll back when the final 3% fails");
        assertEq(address(hook).balance, 1 ether);
        vm.prank(TEAM);
        hook.updateFeeAddress(TEAM);
        uint256 before = TEAM.balance;
        hook.flush();
        assertEq(TEAM.balance - before, 0.03 ether);
        assertEq(address(pool).balance - retained, 0.97 ether);
        assertEq(address(hook).balance, 0);
    }

    function test_FalseReturningTokenCannotPartiallyAddOrWithdraw() public {
        uint128 liq = pool.liquidity();
        uint256 eth = TEAM.balance;
        uint256 tokens = coin.balanceOf(TEAM);
        vm.mockCall(address(coin), abi.encodeWithSelector(coin.transferFrom.selector), abi.encode(false));
        vm.prank(TEAM);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        pool.addLiquidity{value: 1 ether}(1 ether, TEAM);
        assertEq(pool.liquidity(), liq);
        assertEq(TEAM.balance, eth);
        assertEq(coin.balanceOf(TEAM), tokens);
        vm.clearMockedCalls();
        // Mock only the final recipient transfer, not the real manager's transfer to the pool.
        vm.mockCall(address(coin), abi.encodeWithSelector(coin.transfer.selector, TEAM), abi.encode(false));
        vm.prank(TEAM);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        pool.removeLiquidity(liq, TEAM, TEAM);
        assertEq(pool.liquidity(), liq);
        assertEq(TEAM.balance, eth, "ETH transfer must roll back if the subsequent token transfer fails");
        assertEq(coin.balanceOf(TEAM), tokens);
        vm.clearMockedCalls();
        vm.prank(TEAM);
        pool.removeLiquidity(liq, TEAM, TEAM);
        assertEq(pool.liquidity(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ImmediateAddRemoveCannotCreateValue(uint256 ethSeed, uint256 coinSeed) public {
        uint256 eth = bound(ethSeed, 2, 10 ether);
        uint256 tokens = bound(coinSeed, 2, 10 ether);
        uint256 ethBefore = TEAM.balance;
        uint256 coinBefore = coin.balanceOf(TEAM);
        uint128 liq = pool.liquidity();
        vm.startPrank(TEAM);
        pool.addLiquidity{value: eth}(tokens, TEAM);
        uint128 added = pool.liquidity() - liq;
        assertGt(added, 0);
        pool.removeLiquidity(added, TEAM, TEAM);
        vm.stopPrank();
        assertEq(pool.liquidity(), liq);
        assertLe(TEAM.balance, ethBefore);
        assertLe(coin.balanceOf(TEAM), coinBefore);
        assertLe(ethBefore - TEAM.balance, 1, "one rounding unit per native roundtrip");
        assertLe(coinBefore - coin.balanceOf(TEAM), 1, "one rounding unit per coin roundtrip");
    }

    function test_RoundTripMinimumAndUnbalancedAmounts() public {
        testFuzz_ImmediateAddRemoveCannotCreateValue(2, 2);
        testFuzz_ImmediateAddRemoveCannotCreateValue(2, 10 ether);
        testFuzz_ImmediateAddRemoveCannotCreateValue(10 ether, 2);
        vm.startPrank(TEAM);
        vm.expectRevert(IMD6900PerpPool.ZeroLiquidity.selector);
        pool.addLiquidity{value: 1}(1, TEAM);
        vm.stopPrank();
    }
}
