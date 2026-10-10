// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IMD6900PerpsLaunch} from "../src/IMD6900PerpsLaunch.sol";
import {IMD6900PerpHook} from "../src/IMD6900PerpHook.sol";

/// Raw CREATE2 is deliberately used: Foundry can exclude Solidity `new` deployments from gas accounting.
contract MeteredLaunchFactory {
    function deploy(bytes memory init, bytes32 salt) external returns (IMD6900PerpsLaunch launch) {
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(init, 32), mload(init), salt)
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        return IMD6900PerpsLaunch(deployed);
    }
}

/// Test-only exposure of the production miner; no alternate mining implementation is deployed by the application.
contract LaunchMiningHarness is IMD6900PerpsLaunch {
    constructor()
        IMD6900PerpsLaunch(
            IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951),
            10000,
            0x35dA9C0303507ddf708E87F2568EdDf12c47a059,
            0x35dA9C0303507ddf708E87F2568EdDf12c47a059
        )
    {}

    function mine(bytes32 hash) external view returns (bytes32) {
        return _mine(hash);
    }

    function maxTries() external pure returns (uint256) {
        return MAX_TRIES;
    }
}

contract LaunchAdmissionTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant OWNER = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059;
    uint256 constant TX_CAP = 1 << 24;
    // The raw helper does not implement the production factory's accounting. Reserve headroom for that wrapper.
    uint256 constant FACTORY_HEADROOM = 100_000;
    // Original failing proof's launch address and hook init hash; independent of future edits to launch bytecode.
    address constant EXPENSIVE_LAUNCH = 0x520B9261909cF1e9451ff4773a207B8430020778;
    bytes32 constant EXPENSIVE_HASH = 0x50a409531c0946fb07fdb3cea5ada7e7ef601852fb8ac9a75db98adb7887c7ee;

    function _init() internal pure returns (bytes memory) {
        return abi.encodePacked(type(IMD6900PerpsLaunch).creationCode, abi.encode(PM, uint24(10000), OWNER, OWNER));
    }

    function _factory(address at) internal returns (MeteredLaunchFactory f) {
        MeteredLaunchFactory implementation = new MeteredLaunchFactory();
        vm.etch(at, address(implementation).code);
        f = MeteredLaunchFactory(at);
    }

    function _intrinsic(bytes memory data) internal pure returns (uint256 gas) {
        gas = 21_000;
        for (uint256 i; i < data.length; ++i) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }

    function _deploy(MeteredLaunchFactory f, bytes32 salt) internal returns (uint256 used, uint256 tries) {
        bytes memory init = _init();
        bytes memory callData = abi.encodeCall(f.deploy, (init, salt));
        uint256 allowance = TX_CAP - _intrinsic(callData) - FACTORY_HEADROOM;
        uint256 start = gasleft();
        (bool ok, bytes memory result) = address(f).call{gas: allowance}(callData);
        used = start - gasleft();
        assertTrue(ok, "raw deployment must succeed within the transaction budget");
        assertGt(used, 3_000_000, "constructor gas must actually be metered");
        assertLt(used + _intrinsic(callData) + FACTORY_HEADROOM, TX_CAP);
        IMD6900PerpsLaunch launch = abi.decode(result, (IMD6900PerpsLaunch));
        assertEq(launch.pool().owner(), OWNER);
        assertEq(launch.hook().owner(), OWNER);
        assertEq(launch.hook().feeAddress(), OWNER);
        assertEq(uint160(address(launch.hook())) & Hooks.ALL_HOOK_MASK, launch.FLAGS());
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(f), salt, keccak256(init))))));
        assertEq(address(launch), predicted);
        tries = uint256(launch.salt()) + 1;
    }

    function test_FitsOneTransactionWithMeteredCreate2() public {
        (uint256 gas, uint256 tries) = _deploy(_factory(address(0xBEEF)), bytes32(uint256(50149)));
        emit log_named_uint("metered launch execution gas", gas);
        emit log_named_uint("mining attempts", tries);
    }

    function test_MeteredFactorySaltSample() public {
        MeteredLaunchFactory f = _factory(address(0xBEEF));
        uint256 worst;
        for (uint256 i; i < 24; ++i) {
            (uint256 used,) = _deploy(f, bytes32(i));
            if (used > worst) worst = used;
        }
        emit log_named_uint("worst execution gas in 24 salts", worst);
    }

    /// Optional rehearsal for the admission worker: no RPC or signing, and no guessed factory address/salt.
    /// The real deployment service must also simulate its complete transaction, including its actual overhead.
    function test_ActualFactorySaltWhenProvided() public {
        address factory = vm.envOr("IMD_PROJECT_FACTORY", address(0));
        if (factory == address(0)) vm.skip(true);
        bytes32 salt = vm.envBytes32("IMD_PROJECT_SALT_0");
        (uint256 gas, uint256 tries) = _deploy(_factory(factory), salt);
        emit log_named_uint("actual factory constructor execution gas", gas);
        emit log_named_uint("actual factory mining attempts", tries);
    }

    function _miner() internal returns (LaunchMiningHarness h) {
        LaunchMiningHarness implementation = new LaunchMiningHarness();
        vm.etch(EXPENSIVE_LAUNCH, address(implementation).code);
        h = LaunchMiningHarness(EXPENSIVE_LAUNCH);
    }

    function test_OriginalExpensiveSearchStillFitsMiningBudget() public {
        LaunchMiningHarness h = _miner();
        uint256 start = gasleft();
        bytes32 salt = h.mine(EXPENSIVE_HASH);
        uint256 used = start - gasleft();
        assertEq(uint256(salt), 132474, "must not get cheaper by changing the CREATE2 input");
        assertLt(used, 12_000_000);
        emit log_named_uint("original 132475-attempt search gas", used);
    }

    function test_ExhaustedSearchRevertsWithinMiningBudget() public {
        LaunchMiningHarness h = _miner();
        // At this address, hash 9044 has no match among the first 134144 salts.
        uint256 start = gasleft();
        (bool ok, bytes memory reason) = address(h).staticcall(abi.encodeCall(h.mine, (bytes32(uint256(9044)))));
        uint256 used = start - gasleft();
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(IMD6900PerpsLaunch.NoSalt.selector));
        assertLt(used, 12_060_000, "exhaustion returns NoSalt, not out of gas");
        emit log_named_uint("exhausted search gas", used);
    }

    function test_WorstSearchBudgetLeavesRoomForDeployment() public {
        MeteredLaunchFactory f = _factory(address(0xBEEF));
        (uint256 deploymentGas,) = _deploy(f, bytes32(0));
        bytes memory init = _init();
        address launchAddress = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(f), bytes32(0), keccak256(init)))))
        );
        IMD6900PerpsLaunch launch = IMD6900PerpsLaunch(launchAddress);
        bytes32 salt = launch.salt();
        bytes32 hookHash = keccak256(
            abi.encodePacked(
                type(IMD6900PerpHook).creationCode, abi.encode(PM, address(launch.pool()), OWNER, OWNER, uint24(10000))
            )
        );
        LaunchMiningHarness h = _miner();
        vm.etch(launchAddress, address(h).code);
        uint256 start = gasleft();
        bytes32 replay = LaunchMiningHarness(launchAddress).mine(hookHash);
        uint256 miningGas = start - gasleft();
        assertEq(replay, salt);
        // Replace this deployment's measured search with the exhaustive-search ceiling, plus margin for the
        // winning batch's rescan and constructor/runtime compiler differences. The actual factory rehearsal
        // remains necessary; its wrapper is external to this repository.
        uint256 worst = deploymentGas - miningGas + 12_060_000 + 25_000
            + _intrinsic(abi.encodeCall(f.deploy, (init, bytes32(0)))) + FACTORY_HEADROOM;
        emit log_named_uint("worst search plus deployment budget", worst);
        assertLt(worst, TX_CAP);
    }

    function testFuzz_MinerReturnsFirstMatchingCreate2Salt(bytes32 hash) public {
        LaunchMiningHarness h = _miner();
        uint256 limit = h.maxTries();
        // A separate reference preimage, allocated through Solidity rather than using the miner's scratch memory.
        bytes memory preimage = abi.encodePacked(bytes1(0xff), EXPENSIVE_LAUNCH, bytes32(0), hash);
        uint160 flags = h.FLAGS();
        uint256 expected;
        for (; expected < limit; ++expected) {
            assembly ("memory-safe") { mstore(add(preimage, 53), expected) }
            if (uint160(uint256(keccak256(preimage))) & Hooks.ALL_HOOK_MASK == flags) break;
        }
        if (expected == limit) {
            vm.expectRevert(IMD6900PerpsLaunch.NoSalt.selector);
            h.mine(hash);
        } else {
            assertEq(uint256(h.mine(hash)), expected);
        }
    }
}
