// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IMD6900PerpPool} from "src/IMD6900PerpPool.sol";

/// Exposes only arithmetic; all lifecycle/invariant tests deploy the unmodified production contracts.
contract LiquidityMathProbe is IMD6900PerpPool {
    constructor()
        IMD6900PerpPool(
            IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951), 10000, 0x35dA9C0303507ddf708E87F2568EdDf12c47a059
        )
    {}

    function quote(uint160 sqrtPrice, uint256 eth, uint256 tokens) external pure returns (uint128) {
        return _fullRangeLiquidity(sqrtPrice, eth, tokens);
    }
}

contract PerpsLiquidityMathTest is Test {
    LiquidityMathProbe internal probe;
    uint160 internal lower;
    uint160 internal upper;

    function setUp() public {
        probe = new LiquidityMathProbe();
        lower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(60));
        upper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(60));
    }

    /// An independent oracle: v4 rounds the actual token debts up, whereas the application chooses liquidity.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_QuotedLiquidityNeverExceedsEitherFundingBudget(int24 tickSeed, uint128 ethSeed, uint128 tokenSeed)
        public
        view
    {
        int24 tick = int24(bound(int256(tickSeed), TickMath.minUsableTick(60) + 1, TickMath.maxUsableTick(60) - 1));
        uint160 price = TickMath.getSqrtPriceAtTick(tick);
        uint128 liq = probe.quote(price, ethSeed, tokenSeed);
        uint256 ethDebt = SqrtPriceMath.getAmount0Delta(price, upper, liq, true);
        uint256 tokenDebt = SqrtPriceMath.getAmount1Delta(lower, price, liq, true);
        assertLe(ethDebt, ethSeed, "v4 must not charge more ETH than the caller supplied");
        assertLe(tokenDebt, tokenSeed, "v4 must not charge more coin than the caller supplied");
        // More of either funding asset cannot reduce liquidity; zero is an allowed dust quote.
        assertGe(probe.quote(price, uint256(ethSeed) + 1, tokenSeed), liq);
        assertGe(probe.quote(price, ethSeed, uint256(tokenSeed) + 1), liq);
    }

    function test_FullRangeEndpointsAndEmptyBudgets() public view {
        assertEq(probe.quote(0, 1 ether, 1 ether), 0);
        assertEq(probe.quote(lower - 1, 1 ether, 1 ether), 0);
        assertEq(probe.quote(lower, 1 ether, 1 ether), 0);
        assertEq(probe.quote(upper, 1 ether, 1 ether), 0);
        assertEq(probe.quote(upper + 1, 1 ether, 1 ether), 0);
        assertEq(probe.quote(type(uint160).max, 1 ether, 1 ether), 0);
        assertEq(probe.quote(1 << 96, 0, 1 ether), 0);
        assertEq(probe.quote(1 << 96, 1 ether, 0), 0);
        assertEq(probe.quote(1 << 96, 1, 1), 0);
        assertEq(probe.quote(1 << 96, 2, 2), 1);
        assertEq(
            probe.quote(1 << 96, uint256(type(uint128).max) * 2, uint256(type(uint128).max) * 2), type(uint128).max
        );
    }
}
