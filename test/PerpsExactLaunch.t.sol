// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe as Vm} from "forge-std/Vm.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IMD6900PerpsLaunch} from "src/IMD6900PerpsLaunch.sol";
import {IMD6900PerpHook} from "src/IMD6900PerpHook.sol";
import {IMD6900PerpPool} from "src/IMD6900PerpPool.sol";

contract PerpsExactLaunchTest is Test {
    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant TEAM = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059;

    function test_DeploysOnAFreshChainWithExactArgumentsAndNoPreexistingCalls() public {
        vm.chainId(4663);
        assertEq(address(MANAGER).code.length, 0);
        vm.startStateDiffRecording();
        IMD6900PerpsLaunch l = new IMD6900PerpsLaunch(MANAGER, 10000, TEAM, TEAM);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 creates;
        uint256 calls;
        for (uint256 i; i < accesses.length; ++i) {
            Vm.AccountAccess memory a = accesses[i];
            if (a.kind == Vm.AccountAccessKind.Create) {
                ++creates;
                assertFalse(a.reverted);
                assertTrue(a.account == address(l) || a.account == address(l.pool()) || a.account == address(l.hook()));
            }
            if (a.kind == Vm.AccountAccessKind.Call || a.kind == Vm.AccountAccessKind.StaticCall) {
                ++calls;
                assertTrue(
                    a.account == address(l.pool()) || a.account == address(l.hook()),
                    "constructor called an existing dependency"
                );
            }
            assertTrue(
                a.kind != Vm.AccountAccessKind.DelegateCall && a.kind != Vm.AccountAccessKind.CallCode
                    && a.kind != Vm.AccountAccessKind.SelfDestruct
            );
        }
        assertEq(creates, 3, "only launch, pool and hook are deployed");
        assertGe(calls, 2, "the trace must observe wiring and ownership transfer");
        assertEq(l.pool().owner(), TEAM);
        assertEq(l.hook().owner(), TEAM);
        assertEq(l.hook().feeAddress(), TEAM);
        assertEq(address(l.pool().poolManager()), address(MANAGER));
        assertEq(address(l.hook().poolManager()), address(MANAGER));
        assertEq(l.pool().poolFee(), 10000);
        assertEq(l.hook().poolFeePips(), 10000);
        assertEq(l.pool().hook(), address(l.hook()));
        assertEq(l.hook().launcher(), address(l.pool()));
        assertEq(l.pool().token(), address(0), "the launch does not name the coin");
        assertEq(l.pool().curve(), address(0));
        assertEq(l.pool().perpEngine(), address(0));
        assertEq(l.hook().perpEngine(), address(0));
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(IMD6900PerpHook).creationCode, abi.encode(MANAGER, address(l.pool()), TEAM, TEAM, uint24(10000))
            )
        );
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(l), l.salt(), initHash)))));
        assertEq(address(l.hook()), predicted, "the launch itself is the CREATE2 deployer");
        assertEq(l.FLAGS(), 0x2ac0, "pin the requested permissions independently of the implementation");
        assertEq(uint160(predicted) & Hooks.ALL_HOOK_MASK, 0x2ac0);
        Hooks.Permissions memory p = l.hook().getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeAddLiquidity && p.beforeRemoveLiquidity && p.beforeSwap && p.afterSwap);
        assertFalse(
            p.afterInitialize || p.afterAddLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate
        );
        assertFalse(
            p.beforeSwapReturnDelta || p.afterSwapReturnDelta || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
    }

    function test_PassesTheAdmissionScanWithExactArguments() public {
        IMD6900PerpsLaunch l = new IMD6900PerpsLaunch(MANAGER, 10000, TEAM, TEAM);
        assertLe(type(IMD6900PerpsLaunch).creationCode.length + 4 * 32, 49152);
        assertLe(address(l).code.length, 24576);
        assertLe(address(l.pool()).code.length, 24576);
        assertLe(address(l.hook()).code.length, 24576);
        _scan(type(IMD6900PerpsLaunch).creationCode);
        _scan(type(IMD6900PerpPool).creationCode);
        _scan(type(IMD6900PerpHook).creationCode);
        _scan(address(l).code);
        _scan(address(l.pool()).code);
        _scan(address(l.hook()).code);
    }

    function test_InvalidConstructorArgumentsRevertTheWholeLaunch() public {
        vm.expectRevert(IMD6900PerpsLaunch.BadHook.selector);
        new IMD6900PerpsLaunch(MANAGER, 0x800000, TEAM, TEAM);
        vm.expectRevert(IMD6900PerpsLaunch.BadHook.selector);
        new IMD6900PerpsLaunch(MANAGER, 1_000_001, TEAM, TEAM);
        vm.expectRevert(IMD6900PerpsLaunch.BadHook.selector);
        new IMD6900PerpsLaunch(MANAGER, 10000, TEAM, address(0));
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        new IMD6900PerpsLaunch(MANAGER, 10000, address(0), TEAM);
    }

    function _scan(bytes memory code) internal pure {
        assertGt(code.length, 0);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf2 && op != 0xf4 && op != 0xff, "forbidden executable opcode");
        }
    }
}
