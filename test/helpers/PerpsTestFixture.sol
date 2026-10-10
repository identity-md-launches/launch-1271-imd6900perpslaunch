// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IMD6900PerpsLaunch} from "src/IMD6900PerpsLaunch.sol";
import {IMD6900PerpHook} from "src/IMD6900PerpHook.sol";
import {IMD6900PerpPool} from "src/IMD6900PerpPool.sol";
import {Coin, Trader} from "../IMD6900Perps.t.sol";
import {MovableCurve} from "../AuditFixes.t.sol";

/// A local market at one coin unit per wei makes rounding losses independently measurable.
/// Only the external coin/curve/engine are doubles; launch, hook, pool and v4 accounting are real.
abstract contract PerpsTestFixture is Test {
    address internal constant TEAM = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059;
    uint160 internal constant Q96 = 1 << 96;
    IPoolManager internal manager;
    IMD6900PerpsLaunch internal launch;
    IMD6900PerpPool internal pool;
    IMD6900PerpHook internal hook;
    Coin internal coin;
    MovableCurve internal referenceCurve;
    Trader internal router;
    PoolKey internal key;

    function setUp() public virtual {
        manager = IPoolManager(address(new PoolManager(address(this))));
        launch = new IMD6900PerpsLaunch(manager, 10_000, TEAM, TEAM);
        pool = launch.pool();
        hook = launch.hook();
        coin = new Coin();
        referenceCurve = new MovableCurve(address(coin), 1 ether, 1 ether);
        vm.deal(TEAM, 1000 ether);
        coin.mint(TEAM, 1000 ether);
        vm.startPrank(TEAM);
        coin.approve(address(pool), type(uint256).max);
        pool.open{value: 100 ether}(address(coin), address(referenceCurve), Q96, 100 ether);
        vm.stopPrank();
        key = pool.poolKey();
        router = new Trader(manager);
        vm.deal(address(router), 1000 ether);
        coin.mint(address(router), 1000 ether);
    }

    function _alignReference() internal {
        referenceCurve.set(Q96, hook.poolPriceX96());
        assertEq(hook.deviationBps(), 0);
    }

    function _expectCallError(address target, address caller, bytes memory data, bytes4 errorSelector) internal {
        vm.prank(caller);
        (bool ok, bytes memory reason) = target.call(data);
        assertFalse(ok, "call unexpectedly succeeded");
        assertEq(reason, abi.encodeWithSelector(errorSelector), "wrong failure path");
    }

    receive() external payable {}
}

/// The future engine's public interface, with controllable availability and status codes.
contract SweepAndBookDouble {
    uint256 public status;
    uint256 public openCount;
    bool public unavailable;
    bool public liquidatable;
    uint256 public calls;
    address public lastLiquidator;
    int256 public lastSpec;
    bool public lastBuy;
    uint160 public lastLimit;
    error EngineDown();

    function configure(uint256 status_, uint256 count_, bool unavailable_, bool liquidatable_) external {
        status = status_;
        openCount = count_;
        unavailable = unavailable_;
        liquidatable = liquidatable_;
    }

    function sweepLiquidations(address liquidator, int256 spec, bool buy, uint160 limit) external returns (uint256) {
        if (unavailable) revert EngineDown();
        ++calls;
        lastLiquidator = liquidator;
        lastSpec = spec;
        lastBuy = buy;
        lastLimit = limit;
        return status;
    }

    function openIds() external view returns (uint256[] memory ids) {
        if (unavailable) revert EngineDown();
        ids = new uint256[](openCount);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = i + 1;
        }
    }

    function isLiquidatable(uint256) external view returns (bool) {
        if (unavailable) revert EngineDown();
        return liquidatable;
    }
}

contract RecordingFeeSink {
    uint256 public received;
    bool public rejects;
    error SinkRejected();

    function setRejects(bool value) external {
        rejects = value;
    }

    function addFees() external payable {
        if (rejects) revert SinkRejected();
        received += msg.value;
    }
}
