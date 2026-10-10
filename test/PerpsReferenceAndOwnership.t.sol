// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IMD6900PerpHook, PonsLaunchedToken} from "src/IMD6900PerpHook.sol";
import {IMD6900PerpPool} from "src/IMD6900PerpPool.sol";
import {PerpsTestFixture} from "./helpers/PerpsTestFixture.sol";

contract GraduationFactoryDouble {
    PonsLaunchedToken internal launched;
    bool public rejects;
    error FactoryUnavailable();

    constructor(address token, address pair) {
        launched.token = token;
        launched.pairToken = pair;
        launched.poolFee = 3000;
        launched.tickSpacing = 60;
        launched.exists = true;
        launched.phase = 2;
    }

    function configure(uint8 phase, bool exists, bool reject) external {
        launched.phase = phase;
        launched.exists = exists;
        rejects = reject;
    }

    function getLaunchedToken(address) external view returns (PonsLaunchedToken memory) {
        if (rejects) revert FactoryUnavailable();
        return launched;
    }

    function memeHook() external pure returns (address) {
        return address(0);
    }
}

contract ReferenceCurveDouble {
    address public immutable token;
    address public immutable factory;
    bool public graduated;
    uint256 public q = 1 ether;
    uint256 public t = 1 ether;

    constructor(address token_, address factory_) {
        token = token_;
        factory = factory_;
    }

    function set(bool graduated_, uint256 q_, uint256 t_) external {
        graduated = graduated_;
        q = q_;
        t = t_;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (q, t);
    }

    function pairToken() external pure returns (address) {
        return address(0);
    }
}

contract PerpsReferenceAndOwnershipTest is PerpsTestFixture {
    function _reference(address pair) internal returns (ReferenceCurveDouble c, GraduationFactoryDouble f) {
        f = new GraduationFactoryDouble(address(coin), pair);
        c = new ReferenceCurveDouble(address(coin), address(f));
        vm.prank(TEAM);
        pool.setCurve(address(c));
    }

    function test_GraduationSwitchesFromFrozenCurveToActualV4ReferencePool() public {
        (ReferenceCurveDouble c,) = _reference(address(0));
        c.set(false, 1 ether, 2 ether);
        assertEq(hook.ponsPriceX96(), uint256(Q96) * 2);
        PoolKey memory ponsKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(coin)), 3000, 60, IHooks(address(0)));
        manager.initialize(ponsKey, Q96 * 2);
        c.set(true, 1 ether, 999 ether); // obsolete reserves must no longer be consulted
        assertEq(hook.ponsPriceX96(), uint256(Q96) * 4);
        assertEq(hook.ponsPriceUnchecked(), uint256(Q96) * 4);
        assertEq(hook.deviationBps(), 7500);
    }

    function test_GraduatedCoinSortingFirstInvertsTheReference() public {
        address pair = address(type(uint160).max);
        (ReferenceCurveDouble c,) = _reference(pair);
        PoolKey memory ponsKey =
            PoolKey(Currency.wrap(address(coin)), Currency.wrap(pair), 3000, 60, IHooks(address(0)));
        manager.initialize(ponsKey, Q96 * 2);
        c.set(true, 1 ether, 1 ether);
        assertEq(hook.ponsPriceX96(), uint256(Q96) / 4);
        assertEq(hook.deviationBps(), 30000);
    }

    function test_IncompleteOrBrokenGraduationDisablesBandButPreventsPairing() public {
        (ReferenceCurveDouble c, GraduationFactoryDouble f) = _reference(address(0));
        c.set(true, 1 ether, 1 ether);
        // An uninitialized v4 reference has no price even with phase 2 metadata.
        assertEq(hook.ponsPriceX96(), 0);
        for (uint256 mode; mode < 3; ++mode) {
            f.configure(mode == 0 ? 1 : 2, mode != 1, mode == 2);
            assertEq(hook.ponsPriceX96(), 0);
            vm.expectRevert(IMD6900PerpPool.NoPonsReference.selector);
            pool.compound(0, 0);
            vm.expectRevert(IMD6900PerpPool.NoPonsReference.selector);
            pool.addLiquidity(0, TEAM);
            // Missing Pons data must not halt ordinary spot trading.
            router.swap(key, true, -0.01 ether);
        }
        vm.prank(TEAM);
        pool.setCurve(address(referenceCurve));
        assertGt(hook.ponsPriceX96(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ReservePriceIsMonotoneAndScaleInvariant(uint96 quoteSeed, uint96 tokenSeed) public {
        uint256 q = bound(quoteSeed, 1, type(uint96).max);
        uint256 t = bound(tokenSeed, 1, type(uint96).max);
        referenceCurve.set(q, t);
        uint256 before = hook.ponsPriceX96();
        // Remainder bounds independently specify the rational price's rounding direction.
        assertLe(before * q, t * uint256(Q96));
        assertLt(t * uint256(Q96) - before * q, q);
        referenceCurve.set(q * 2, t * 2);
        assertEq(hook.ponsPriceX96(), before);
        referenceCurve.set(q, t * 2);
        assertGe(hook.ponsPriceX96(), before);
        referenceCurve.set(q * 2, t);
        assertLe(hook.ponsPriceX96(), before);
    }

    function test_EmptyAndOverflowingReferenceReturnsNoPrice() public {
        referenceCurve.set(0, 1);
        assertEq(hook.ponsPriceX96(), 0);
        referenceCurve.set(1, 0);
        assertEq(hook.ponsPriceX96(), 0);
        referenceCurve.set(1, type(uint256).max);
        assertEq(hook.ponsPriceX96(), 0, "guard catches unrepresentable reference arithmetic");
        vm.expectRevert(); // FullMath's checked 512-bit division, inside the unguarded read only
        hook.ponsPriceUnchecked();
    }

    function test_HandoverExpiryBoundaryAndRequestIsolationOnBothContracts() public {
        address alice = makeAddr("handover candidate Alice");
        address bob = makeAddr("handover candidate Bob");
        address[2] memory targets = [address(hook), address(pool)];
        for (uint256 i; i < targets.length; ++i) {
            Ownable o = Ownable(targets[i]);
            vm.prank(alice);
            o.requestOwnershipHandover();
            uint256 expires = o.ownershipHandoverExpiresAt(alice);
            assertEq(expires, vm.getBlockTimestamp() + 48 hours);
            vm.prank(bob);
            o.requestOwnershipHandover();
            vm.prank(bob);
            o.cancelOwnershipHandover();
            assertEq(o.ownershipHandoverExpiresAt(bob), 0);
            assertEq(o.ownershipHandoverExpiresAt(alice), expires, "candidates cannot cancel one another");
            assertEq(o.owner(), TEAM, "request alone grants no privileges");
            vm.warp(expires);
            vm.prank(TEAM);
            o.completeOwnershipHandover(alice);
            assertEq(o.owner(), alice, "completion is allowed at the exact expiry second");
            assertEq(o.ownershipHandoverExpiresAt(alice), 0, "consumed once");
            vm.prank(TEAM);
            vm.expectRevert(Ownable.Unauthorized.selector);
            o.transferOwnership(TEAM);
            vm.prank(alice);
            vm.expectRevert(Ownable.NoHandoverRequest.selector);
            o.completeOwnershipHandover(alice);
            vm.prank(alice);
            vm.expectRevert(bytes4(keccak256("NoRenounce()")));
            o.renounceOwnership();
            vm.prank(alice);
            o.transferOwnership(TEAM);
        }
    }

    function test_TransferringOneOwnerDoesNotChangeTheOtherOrRedirectExistingFees() public {
        address next = makeAddr("next hook owner");
        vm.prank(TEAM);
        hook.transferOwnership(next);
        assertEq(pool.owner(), TEAM);
        assertEq(hook.feeAddress(), TEAM);
        vm.deal(address(hook), 100);
        uint256 before = TEAM.balance;
        hook.flush();
        assertEq(TEAM.balance, before + 3);
        vm.prank(next);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.removeLiquidity(1, next, next);
        vm.prank(TEAM);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setBand(1);
        vm.prank(next);
        hook.setBand(1);
        assertEq(hook.maxDeviationBps(), 1);
        // The fee recipient retains its independent right to renounce after hook ownership moves.
        vm.prank(TEAM);
        hook.renounceFeeAddress();
        assertTrue(hook.feeAddressRenounced());
        assertEq(hook.feeAddress(), address(pool));
    }
}
