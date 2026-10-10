// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AuditFixesTest, BrokenCurve} from "./AuditFixes.t.sol";
import {IMD6900PerpsLaunch} from "../src/IMD6900PerpsLaunch.sol";
import {IMD6900PerpPool} from "../src/IMD6900PerpPool.sol";
import {IMD6900PerpHook} from "../src/IMD6900PerpHook.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// Exercises a swap at zero liquidity; no settlement is needed because both amounts are zero.
contract EmptyPoolTrader {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function swap(PoolKey memory key, uint160 price) external returns (BalanceDelta) {
        return abi.decode(pm.unlock(abi.encode(key, price)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm));
        (PoolKey memory key, uint160 price) = abi.decode(data, (PoolKey, uint160));
        return abi.encode(pm.swap(key, SwapParams(true, -1, price), ""));
    }
}

/// Reuses the accepted real-PoolManager fixture and retains the earlier audit regressions.
contract RevisionFixesTest is AuditFixesTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function _earnFees() internal {
        for (uint256 i; i < 6; ++i) {
            trader.swap(key, true, -0.1 ether);
            trader.swap(key, false, -9e25);
        }
        _parkCurveAtThePool();
    }

    // 411b0e14: idle ETH can pair with coin fees still held by the PoolManager.
    function test_CompoundCollectsEarnedCoinFees() public {
        _earnFees();
        vm.deal(address(pool), 1 ether);
        assertEq(coin.balanceOf(address(pool)), 0);
        uint128 before = pool.liquidity();
        uint256 callerEth = address(this).balance;
        uint256 callerCoin = coin.balanceOf(address(this));
        pool.compound(0, 0);
        assertGt(pool.liquidity(), before);
        assertLt(address(pool).balance, 1 ether + 0.06 ether);
        assertEq(address(this).balance, callerEth, "the caller receives no ETH fees");
        assertEq(coin.balanceOf(address(this)), callerCoin, "the caller receives no coin fees");
    }

    function test_CompoundCollectsWhenBothIdleBalancesAreEmpty() public {
        _earnFees();
        assertEq(coin.balanceOf(address(pool)), 0);
        vm.deal(address(pool), 0);
        uint128 before = pool.liquidity();
        pool.compound(0, 0);
        assertGt(pool.liquidity(), before);
    }

    function test_CompoundCollectionStillHonorsMinimumsAndPonsGuard() public {
        _earnFees();
        vm.deal(address(pool), 1 ether);
        uint128 before = pool.liquidity();
        vm.expectRevert(IMD6900PerpPool.ZeroLiquidity.selector);
        pool.compound(2 ether, 0);
        assertEq(coin.balanceOf(address(pool)), 0, "fee collection rolls back with the minimum check");
        assertEq(pool.liquidity(), before);
        curve.set(1 ether, 2e27);
        vm.expectRevert(abi.encodeWithSelector(IMD6900PerpPool.OffPons.selector, hook.deviationBps()));
        pool.compound(0, 0);
        address broken = address(new BrokenCurve());
        vm.prank(OWNER);
        pool.setCurve(broken);
        vm.expectRevert(IMD6900PerpPool.NoPonsReference.selector);
        pool.compound(0, 0);
    }

    function test_UnmatchedIdleEthNeedsCoinAndRemainsRecoverable() public {
        vm.deal(address(pool), 1 ether);
        vm.expectRevert(IMD6900PerpPool.ZeroLiquidity.selector);
        pool.compound(0, 0); // no trades, so no matching earned coin yet
        uint128 liq = pool.liquidity();
        vm.prank(OWNER);
        pool.removeLiquidity(liq, OWNER, OWNER);
        assertEq(address(pool).balance, 1 ether, "removeLiquidity pays the position, not idle funds");
        vm.expectRevert(IMD6900PerpPool.ZeroLiquidity.selector);
        pool.compound(0, 0); // do not poke an empty v4 position
        vm.prank(OWNER);
        coin.transfer(address(pool), 1e27);
        pool.compound(0, 0);
        liq = pool.liquidity();
        uint256 before = OWNER.balance;
        vm.prank(OWNER);
        pool.removeLiquidity(liq, OWNER, OWNER);
        assertApproxEqAbs(OWNER.balance - before, 1 ether, 1e6);
    }

    // f44ad048: exemptions only affect the band; all model reads equal the fee actually charged by v4.
    function test_FeeModelAlwaysMatchesStaticFee() public {
        vm.startPrank(OWNER);
        hook.setFeeExempt(address(trader), true);
        hook.setPerpEngine(address(trader));
        vm.expectRevert(IMD6900PerpHook.InvalidFee.selector);
        hook.setPerpFeeBps(0);
        vm.expectRevert(IMD6900PerpHook.InvalidFee.selector);
        hook.setPerpFeeBps(1000);
        hook.setPerpFeeBps(100);
        vm.expectRevert(IMD6900PerpHook.InvalidFee.selector);
        hook.lowerFee(99);
        vm.stopPrank();
        assertFalse(hook.tracksPons(address(trader)));
        assertEq(hook.feeFor(address(trader)), 100);
        assertEq(hook.feeFor(address(0)), 100);
        assertEq(hook.feeBps(), 100);
        assertEq(hook.perpFeeBps(), 100);
        (uint256 g0,) = PM.getFeeGrowthGlobals(key.toId());
        uint128 liq = pool.liquidity();
        trader.swap(key, true, -0.1 ether);
        (uint256 g1,) = PM.getFeeGrowthGlobals(key.toId());
        assertApproxEqAbs(FullMath.mulDiv(g1 - g0, liq, 1 << 128), 0.001 ether, 10);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setPerpFeeBps(100);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.lowerFee(99);
    }

    function test_FeeModelCannotDivergeAtOtherStaticFees() public {
        IMD6900PerpHook high = new IMD6900PerpsLaunch(PM, 200_000, OWNER, OWNER).hook();
        assertEq(high.feeBps(), 2000);
        assertEq(high.perpFeeBps(), 2000, "no cap that understates the real fee");
        vm.startPrank(OWNER);
        high.setPerpFeeBps(2000);
        vm.expectRevert(IMD6900PerpHook.InvalidFee.selector);
        high.lowerFee(1000);
        vm.stopPrank();
        IMD6900PerpHook low = new IMD6900PerpsLaunch(PM, 3000, OWNER, OWNER).hook();
        vm.startPrank(OWNER);
        low.setPerpFeeBps(30);
        low.setFeeExempt(address(trader), true);
        vm.stopPrank();
        assertEq(low.feeFor(address(trader)), 30);
    }

    // af62a280: stale opening prices and unreadable references must revert the entire initialization.
    function test_OpenRejectsStalePriceAndCanRetry() public {
        IMD6900PerpsLaunch fresh = new IMD6900PerpsLaunch(PM, 10000, OWNER, OWNER);
        IMD6900PerpPool p = fresh.pool();
        curve.set(1 ether, 1.25e27);
        coin.mint(OWNER, 2.5e27);
        uint256 ethBefore = OWNER.balance;
        uint256 coinBefore = coin.balanceOf(OWNER);
        vm.startPrank(OWNER);
        coin.approve(address(p), 2.5e27);
        // The fixture's rounded sqrt makes the reported deviation 2000 bps.
        vm.expectRevert(abi.encodeWithSelector(IMD6900PerpPool.OffPons.selector, uint256(2000)));
        p.open{value: 2 ether}(address(coin), address(curve), uint160(_sqrt(1e9)) << 96, 2e27);
        vm.stopPrank();
        assertEq(p.token(), address(0));
        assertEq(p.curve(), address(0));
        assertEq(PoolId.unwrap(fresh.hook().poolId()), bytes32(0));
        assertEq(OWNER.balance, ethBefore);
        assertEq(coin.balanceOf(OWNER), coinBefore);
        // Recompute using the full precision reserve ratio, as the owner script does.
        uint160 price = uint160(_sqrt(FullMath.mulDiv(1.25e27, 1 << 96, 1 ether) << 96));
        vm.prank(OWNER);
        p.open{value: 2 ether}(address(coin), address(curve), price, 2.5e27);
        assertGt(p.liquidity(), 0);
        assertLe(fresh.hook().deviationBps(), 1);
    }

    function test_OpenRequiresReadableReference() public {
        IMD6900PerpPool p = new IMD6900PerpsLaunch(PM, 10000, OWNER, OWNER).pool();
        coin.mint(OWNER, 2e27);
        vm.startPrank(OWNER);
        coin.approve(address(p), 2e27);
        address broken = address(new BrokenCurve());
        vm.expectRevert(IMD6900PerpPool.NoPonsReference.selector);
        p.open{value: 2 ether}(address(coin), broken, uint160(_sqrt(1e9)) << 96, 2e27);
        vm.stopPrank();
        assertEq(p.token(), address(0));
    }

    // 0b0abb0c: pin the existing coin-per-ETH units rather than redesigning the band's economics.
    function test_BandIsDefinedInCoinPerEth() public {
        curve.set(0.7 ether, 1e27);
        assertApproxEqAbs(hook.deviationBps(), 3000, 1);
        curve.set(1.3 ether, 1e27);
        assertApproxEqAbs(hook.deviationBps(), 3000, 1);
        curve.set(1.4286 ether, 1e27);
        assertApproxEqAbs(hook.deviationBps(), 4286, 1);
    }

    // efcd809e / 647fd79c: these are explicit owner powers, not bypasses.
    function test_OwnerCanTransferControlToAnUnusableAddress() public {
        vm.startPrank(OWNER);
        pool.transferOwnership(address(0xdEaD));
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.removeLiquidity(1, OWNER, OWNER);
        hook.transferOwnership(address(0xdEaD));
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setPerpEngine(address(0));
        vm.stopPrank();
    }

    function test_FlushUsesCurrentFeeAddressAndBadEngineCanBeReplaced() public {
        vm.deal(address(hook), 1 ether);
        uint256 before = address(pool).balance;
        vm.prank(OWNER);
        hook.updateFeeAddress(address(0xB0B));
        hook.flush();
        assertEq(address(0xB0B).balance, 0.03 ether);
        assertEq(address(pool).balance - before, 0.97 ether);
        vm.prank(OWNER);
        hook.setPerpEngine(address(0xE));
        vm.expectRevert();
        trader.swap(key, true, -0.01 ether);
        vm.prank(OWNER);
        hook.setSweepFailOpen(true);
        trader.swap(key, true, -0.01 ether);
    }

    // 24e73753: a drained pool is not a usable perps mark, even while its band still applies.
    function test_EmptyPoolPriceCanMoveForFreeInsideBand() public {
        uint128 liq = pool.liquidity();
        vm.prank(OWNER);
        pool.removeLiquidity(liq, OWNER, OWNER);
        uint160 limit = uint160(_sqrt(FullMath.mulDiv(hook.ponsPriceX96(), 3, 4) << 96));
        BalanceDelta d = new EmptyPoolTrader(PM).swap(key, limit);
        assertEq(d.amount0(), 0);
        assertEq(d.amount1(), 0);
        assertApproxEqAbs(hook.deviationBps(), 2500, 1);
    }

    // bbd87e2e: a code-length check does not validate the sink ABI; funds survive a failed forwarding call.
    function test_BadFeeSinkIsRecoverable() public {
        vm.deal(address(hook), 1 ether);
        vm.prank(OWNER);
        pool.setFeeSink(address(curve));
        vm.expectRevert();
        hook.flush();
        assertEq(address(hook).balance, 1 ether);
        vm.prank(OWNER);
        pool.setFeeSink(address(0));
        hook.flush();
        assertEq(address(hook).balance, 0);
        assertEq(address(pool).balance, 0.97 ether);
    }
}
