// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IMD6900PerpsLaunch} from "../src/IMD6900PerpsLaunch.sol";
import {IMD6900PerpHook} from "../src/IMD6900PerpHook.sol";
import {IMD6900PerpPool} from "../src/IMD6900PerpPool.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Coin, Trader} from "./IMD6900Perps.t.sol";

/// A Pons curve whose price can move (the reference the band follows)
contract MovableCurve {
    uint256 public q;
    uint256 public t;
    address public token;

    constructor(address token_, uint256 q_, uint256 t_) {
        token = token_;
        q = q_;
        t = t_;
    }

    function set(uint256 q_, uint256 t_) external {
        q = q_;
        t = t_;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (q, t);
    }

    function graduated() external pure returns (bool) {
        return false;
    }

    function pairToken() external pure returns (address) {
        return address(0);
    }

    function factory() external pure returns (address) {
        return address(0);
    }
}

/// A Pons market that can't be read at all
contract BrokenCurve {
    fallback() external {
        revert("broken");
    }
}

/// A perps engine that can't answer anything
contract DeadEngine {
    fallback() external {
        revert("down");
    }
}

/// The Pons factory as the hook reads it, with the launch graduated but its pool not yet created (phase 1): a state
/// in which the hook has no reference price at all
contract PhaseOneFactory {
    struct L {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function memeHook() external pure returns (address) {
        return address(0);
    }

    function getLaunchedToken(address token) external pure returns (L memory l) {
        l.token = token;
        l.exists = true;
        l.phase = 1;
    }
}

/// A Pons curve at 1e9 coin per ETH that can graduate (after which the hook reads the reference as 0)
contract GraduatingCurve {
    uint256 public q = 1 ether;
    uint256 public t = 1e27;
    address public token;
    bool public graduated;
    address public factory;

    constructor(address token_, address factory_) {
        token = token_;
        factory = factory_;
    }

    function graduate() external {
        graduated = true;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (q, t);
    }

    function pairToken() external pure returns (address) {
        return address(0);
    }
}

/// The IMD swarm audits' findings on this launch (job ea1c84c3: math, permissions, economics, flow, imported code; then
/// the import audit of this relaunch: compound and addLiquidity without a reference or off it, the zero fee address at
/// construction, feeBps against the pool's fee), each fixed and held here
contract AuditFixesTest is Test {
    IPoolManager PM;
    address constant OWNER = address(0xA11CE);
    IMD6900PerpsLaunch l;
    IMD6900PerpHook hook;
    IMD6900PerpPool pool;
    Coin coin;
    MovableCurve curve;
    Trader trader;
    PoolKey key;

    function setUp() public {
        PM = IPoolManager(address(new PoolManager(address(this))));
        l = new IMD6900PerpsLaunch(PM, 10_000, OWNER, OWNER);
        hook = l.hook();
        pool = l.pool();
        coin = new Coin();
        curve = new MovableCurve(address(coin), 1 ether, 1e27); // 1e9 coin per ETH
        coin.mint(OWNER, 2e27);
        vm.deal(OWNER, 10 ether);
        vm.startPrank(OWNER);
        coin.approve(address(pool), type(uint256).max);
        pool.open{value: 2 ether}(address(coin), address(curve), uint160(_sqrt(1e9)) << 96, 2e27);
        vm.stopPrank();
        key = pool.poolKey();
        trader = new Trader(PM);
        vm.deal(address(trader), 100 ether);
        coin.mint(address(trader), 1e28);
    }

    /// economics + flow: compound() paired the pool's idle funds at whatever price the caller had just pushed
    function test_Fix_CompoundOnlyAtThePonsPrice() public {
        vm.deal(address(pool), 0.5 ether);
        coin.mint(address(pool), 5e26);
        curve.set(1 ether, 0.9e27); // Pons moves 10% away from the pool
        vm.expectRevert(abi.encodeWithSelector(IMD6900PerpPool.OffPons.selector, hook.deviationBps()));
        pool.compound(0, 0);
        curve.set(1 ether, 1e27); // back at the pool's price
        uint128 liq0 = pool.liquidity();
        pool.compound(0, 0);
        assertGt(pool.liquidity(), liq0);
    }

    /// permissions + tests: with little gas a down engine was read as "no positions" and the trade went through
    function test_Fix_LowGasSweepFailsClosed() public {
        address dead = address(new DeadEngine());
        vm.prank(OWNER);
        hook.setPerpEngine(dead);
        vm.expectRevert(); // SweepUnavailable, at normal gas
        trader.swap(key, true, -0.01 ether);
        vm.expectRevert(); // and now at low gas too
        trader.swap{gas: 600_000}(key, true, -0.01 ether);
        vm.prank(OWNER);
        hook.setSweepFailOpen(true); // the owner's escape hatch still opens it
        trader.swap{gas: 600_000}(key, true, -0.01 ether);
    }

    /// imported code + economics: a "correction" could swing the pool through the Pons price and far out the other side
    function test_Fix_NoCrossingThroughPons() public {
        curve.set(2 ether, 1e27); // Pons at 0.5e9 coin per ETH: the pool (1e9) is 100% above it
        assertGt(hook.deviationBps(), 9_000);
        vm.expectRevert(); // a buy big enough to end far below Pons: TooFarFromPons
        trader.swap(key, true, -4 ether);
        trader.swap(key, true, -0.5 ether); // a correction that stays on its side is fine
        assertLt(hook.deviationBps(), 10_000);
    }

    /// imported code: a Pons market that couldn't be read halted all trading
    function test_Fix_UnreadablePonsLeavesTradingOpen() public {
        address broken = address(new BrokenCurve());
        vm.prank(OWNER);
        pool.setCurve(broken);
        assertEq(hook.ponsPriceX96(), 0);
        assertEq(hook.deviationBps(), 0);
        trader.swap(key, true, -0.01 ether); // the band is off, the pool trades
        vm.prank(OWNER);
        pool.setCurve(address(curve)); // and the owner can point it right again
        assertLt(hook.deviationBps(), 200);
    }

    /// permissions + economics: a zero fee address, a zero curve, a sink with no code, renounced ownership
    function test_Fix_AdminGuards() public {
        vm.startPrank(OWNER);
        vm.expectRevert(IMD6900PerpHook.ZeroAddress.selector);
        hook.updateFeeAddress(address(0));
        vm.expectRevert(IMD6900PerpHook.NoRenounce.selector);
        hook.renounceOwnership();
        vm.expectRevert(IMD6900PerpPool.NoRenounce.selector);
        pool.renounceOwnership();
        vm.expectRevert(IMD6900PerpPool.NotAContract.selector);
        pool.setFeeSink(address(0xBEEF));
        vm.expectRevert(IMD6900PerpPool.ZeroAddress.selector);
        pool.setCurve(address(0));
        vm.stopPrank();
        IMD6900PerpsLaunch l2 = new IMD6900PerpsLaunch(PM, 10_000, OWNER, OWNER);
        IMD6900PerpPool p2 = l2.pool();
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PerpPool.ZeroAddress.selector);
        p2.open{value: 1 ether}(address(coin), address(0), uint160(1 << 96), 1e18);
    }

    /// imported code: an addition reported principal less the position's earned fees, refunding those fees to the caller
    function test_Fix_AnAdditionLeavesTheEarnedFeesInThePool() public {
        for (uint256 i; i < 6; ++i) {
            // trades both ways: the position earns its 1%
            trader.swap(key, true, -0.1 ether);
            trader.swap(key, false, -9e25);
        }
        _parkCurveAtThePool(); // the trades left the pool ~2.5% off Pons, and an addition runs only within 1% of it
        address lp = address(0xD0E);
        vm.deal(lp, 1 ether);
        coin.mint(lp, 1e27);
        vm.startPrank(lp);
        coin.approve(address(pool), type(uint256).max);
        uint256 before = address(pool).balance;
        pool.addLiquidity{value: 1 ether}(1e27, lp);
        vm.stopPrank();
        assertGt(address(pool).balance, before, "the fees the position earned stayed in the pool, not with the caller");
    }

    /*        The second audit (jobs d07ab5c6 and this launch's import audit), each finding fixed and held        */

    /// economics (90ab2e9d): compound() read "no reference" as "on price": with the Pons price unreadable the band is
    /// off, so a caller pushed the pool, compounded the pool's idle funds at that price and sold back into the depth
    function test_Fix_CompoundRefusesWithoutAReference() public {
        vm.deal(address(pool), 0.5 ether);
        coin.mint(address(pool), 5e26);
        GraduatingCurve g = new GraduatingCurve(address(coin), address(new PhaseOneFactory()));
        vm.prank(OWNER);
        pool.setCurve(address(g));
        g.graduate(); // graduated on Pons, no pool recorded yet: the hook has no price to judge by
        assertEq(hook.ponsPriceX96(), 0, "no reference");
        assertEq(hook.deviationBps(), 0, "the deviation alone reads as on price");
        vm.expectRevert(IMD6900PerpPool.NoPonsReference.selector);
        pool.compound(0, 0);
        // the sandwich the finding ran: push, compound, sell back
        uint256 liq0 = pool.liquidity();
        uint256 before = address(trader).balance;
        trader.swap(key, true, -1 ether);
        try pool.compound(0, 0) {} catch {}
        trader.swap(key, false, -int256(coin.balanceOf(address(trader)) - 1e28));
        assertEq(pool.liquidity(), liq0, "nothing was compounded at the pushed price");
        assertLt(address(trader).balance, before, "the round trip only paid the pool's fee");
        // an unreadable curve is the same state
        address broken = address(new BrokenCurve());
        vm.prank(OWNER);
        pool.setCurve(broken);
        vm.expectRevert(IMD6900PerpPool.NoPonsReference.selector);
        pool.compound(0, 0);
        // the reference back, the pool at its price: compound runs again
        vm.prank(OWNER);
        pool.setCurve(address(curve));
        _parkCurveAtThePool();
        pool.compound(0, 0);
        assertGt(pool.liquidity(), liq0);
    }

    /// economics (2f33186a): addLiquidity() paired the caller's funds at any price inside the 30% band, so a push, an
    /// addition and a sell-back took the difference out of the pool's position; it now runs under compound()'s guard
    function test_Fix_AddLiquidityOnlyAtThePonsPrice() public {
        address donor = address(0xD0E);
        vm.deal(donor, 2 ether);
        coin.mint(donor, 2e27);
        vm.prank(donor);
        coin.approve(address(pool), type(uint256).max);
        uint256 before = address(trader).balance;
        trader.swap(key, true, -0.3 ether); // the push: ~24% off Pons, inside the band
        uint256 dev = hook.deviationBps();
        assertLe(dev, hook.maxDeviationBps(), "the push stays inside the band");
        assertGt(dev, pool.COMPOUND_MAX_DEV_BPS());
        uint128 liq0 = pool.liquidity();
        vm.prank(donor);
        vm.expectRevert(abi.encodeWithSelector(IMD6900PerpPool.OffPons.selector, dev));
        pool.addLiquidity{value: 2 ether}(2e27, donor);
        trader.swap(key, false, -int256(coin.balanceOf(address(trader)) - 1e28)); // sell it all back
        assertEq(pool.liquidity(), liq0);
        assertLt(address(trader).balance, before, "the round trip only paid the pool's fee");
        // no reference at all refuses the addition too
        address broken = address(new BrokenCurve());
        vm.prank(OWNER);
        pool.setCurve(broken);
        vm.prank(donor);
        vm.expectRevert(IMD6900PerpPool.NoPonsReference.selector);
        pool.addLiquidity{value: 2 ether}(2e27, donor);
        // at the Pons price anyone still deepens it
        vm.prank(OWNER);
        pool.setCurve(address(curve));
        _parkCurveAtThePool();
        vm.prank(donor);
        pool.addLiquidity{value: 2 ether}(2e27, donor);
        assertGt(pool.liquidity(), liq0);
    }

    /// permissions (62af2101): the hook's constructor took a zero fee address, and flush() then burnt 3% of what it
    /// forwarded; the launch refuses the argument now (the hook's constructor reverts ZeroAddress, so create2 fails)
    function test_Fix_NoZeroFeeAddressAtConstruction() public {
        vm.expectRevert(IMD6900PerpsLaunch.BadHook.selector);
        new IMD6900PerpsLaunch(PM, 10_000, OWNER, address(0));
        // and with a fee address, flush sends its 3% there, nothing to address(0)
        vm.deal(address(hook), 1 ether);
        uint256 zeroBefore = address(0).balance;
        uint256 ownerBefore = OWNER.balance;
        hook.flush();
        assertEq(address(0).balance, zeroBefore);
        assertEq(OWNER.balance - ownerBefore, 0.03 ether);
    }

    /// economics (93cc8561): feeBps started at 1,000 (10%) while the pool's fee is 100 bps, against the hook's own
    /// rule that the engine's model reads the pool's real fee; both rates now follow poolFeePips from construction
    function test_Fix_FeeBpsFollowsThePoolFee() public {
        assertEq(hook.poolFeePips(), 10_000);
        assertEq(hook.feeBps(), 100, "1% pool fee: 100 bps");
        assertEq(hook.perpFeeBps(), 100);
        assertEq(hook.feeFor(address(0xBEEF)), 100);
        IMD6900PerpsLaunch l3 = new IMD6900PerpsLaunch(PM, 3_000, OWNER, OWNER);
        assertEq(l3.hook().feeBps(), 30, "0.3% pool fee: 30 bps, from construction");
        assertEq(l3.hook().perpFeeBps(), 30);
        // lowerFee keeps its only-lower rule and its floor
        vm.startPrank(OWNER);
        vm.expectRevert(IMD6900PerpHook.InvalidFee.selector);
        hook.lowerFee(100);
        vm.expectRevert(IMD6900PerpHook.InvalidFee.selector);
        hook.lowerFee(99);
        vm.stopPrank();
    }

    /// coverage: the ten ownership entry points IMD6900PerpHook and IMD6900PerpPool inherit from solady's Ownable
    /// (transferOwnership, renounceOwnership, requestOwnershipHandover, cancelOwnershipHandover,
    /// completeOwnershipHandover on each), each answered here
    function test_OwnableEntryPointsOnBoth() public {
        address next = address(0xB0B);
        address[2] memory owned = [address(hook), address(pool)];
        for (uint256 i; i < 2; ++i) {
            Ownable o = Ownable(owned[i]);
            // only the owner transfers, never to nobody, never to zero
            vm.expectRevert(Ownable.Unauthorized.selector);
            o.transferOwnership(next);
            vm.prank(OWNER);
            vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
            o.transferOwnership(address(0));
            vm.prank(OWNER);
            vm.expectRevert(bytes4(keccak256("NoRenounce()")));
            o.renounceOwnership();
            // a handover: requested by the candidate, completed by the owner, within solady's 48h
            vm.prank(OWNER);
            vm.expectRevert(Ownable.NoHandoverRequest.selector);
            o.completeOwnershipHandover(next);
            vm.prank(next);
            o.requestOwnershipHandover();
            assertGt(o.ownershipHandoverExpiresAt(next), vm.getBlockTimestamp());
            vm.expectRevert(Ownable.Unauthorized.selector); // only the owner completes it
            o.completeOwnershipHandover(next);
            vm.prank(next);
            o.cancelOwnershipHandover(); // the candidate can withdraw
            vm.prank(OWNER);
            vm.expectRevert(Ownable.NoHandoverRequest.selector);
            o.completeOwnershipHandover(next);
            vm.prank(next);
            o.requestOwnershipHandover();
            vm.warp(vm.getBlockTimestamp() + 48 hours + 1); // the cheatcode, not block.timestamp: via-IR hoists that out of the loop
            vm.prank(OWNER);
            vm.expectRevert(Ownable.NoHandoverRequest.selector); // expired
            o.completeOwnershipHandover(next);
            vm.prank(next);
            o.requestOwnershipHandover();
            vm.prank(OWNER);
            o.completeOwnershipHandover(next);
            assertEq(o.owner(), next);
            // and a plain transfer back
            vm.prank(next);
            o.transferOwnership(OWNER);
            assertEq(o.owner(), OWNER);
        }
    }

    /// the property the launch keeps: the owner takes all of the liquidity back whatever state the hook is in (an
    /// unreadable reference, a dead engine on the hook, the tightest band), which is how a future hook replaces this one
    function test_OwnerAlwaysTakesTheLiquidityBack() public {
        vm.startPrank(OWNER);
        pool.setCurve(address(new BrokenCurve()));
        hook.setPerpEngine(address(new DeadEngine()));
        hook.setBand(1);
        uint128 liq = pool.liquidity();
        uint256 ethBefore = OWNER.balance;
        pool.removeLiquidity(liq, OWNER, OWNER);
        vm.stopPrank();
        assertEq(pool.liquidity(), 0, "all of it");
        assertApproxEqRel(OWNER.balance - ethBefore, 2 ether, 1e15, "the ETH came back");
        assertApproxEqRel(coin.balanceOf(OWNER), 2e27, 1e15, "the coin came back");
    }

    /// @dev Moves the Pons reference to exactly where the pool's price sits (1 ETH of quote reserve)
    function _parkCurveAtThePool() internal {
        curve.set(1 ether, (hook.poolPriceX96() * 1e18) >> 96);
        assertLe(hook.deviationBps(), 1);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        uint256 r = x;
        uint256 y = (x + 1) / 2;
        while (y < r) {
            r = y;
            y = (x / y + y) / 2;
        }
        z = r;
    }

    receive() external payable {}
}
