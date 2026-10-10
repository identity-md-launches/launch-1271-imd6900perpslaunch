// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IMD6900PerpPool} from "src/IMD6900PerpPool.sol";
import {IMD6900PerpHook} from "src/IMD6900PerpHook.sol";
import {PerpsTestFixture, RecordingFeeSink} from "./helpers/PerpsTestFixture.sol";

contract FeeSequenceHandler is Test {
    IMD6900PerpPool public immutable pool;
    IMD6900PerpHook public immutable hook;
    RecordingFeeSink public immutable sink;
    address public immutable owner;
    address[3] public donors;
    address[3] public recipients;
    mapping(address => uint256) public initialBalance;
    mapping(address => uint256) public feePaid;
    uint256 public totalSent;
    uint256 public pendingHook;
    uint256 public poolRetained;
    uint256 public sinkPaid;
    uint256 public totalFeePaid;
    uint256 public successfulFlushes;
    uint256 public failedForwards;
    bool public renounced;

    constructor(IMD6900PerpPool p, IMD6900PerpHook h) {
        pool = p;
        hook = h;
        owner = p.owner();
        sink = new RecordingFeeSink();
        recipients = [owner, address(0x3001), address(0x3002)];
        poolRetained = address(p).balance;
        totalSent = poolRetained;
        for (uint256 i; i < 3; ++i) {
            donors[i] = address(uint160(0x2001 + i));
            vm.deal(donors[i], 1000 ether);
            initialBalance[recipients[i]] = recipients[i].balance;
        }
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 0, 1 ether);
        vm.prank(donors[actorSeed % 3]);
        (bool ok,) = address(hook).call{value: amount}("");
        assertTrue(ok);
        totalSent += amount;
        pendingHook += amount;
    }

    function flush(uint256 actorSeed) external {
        uint256 amount = pendingHook;
        uint256 fee = renounced ? 0 : amount * 3 / 100;
        address recipient = hook.feeAddress();
        bool toSink = pool.feeSink() != address(0);
        vm.prank(donors[actorSeed % 3]);
        (bool ok, bytes memory result) = address(hook).call(abi.encodeCall(hook.flush, ()));
        if (amount != 0 && toSink && sink.rejects()) {
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(RecordingFeeSink.SinkRejected.selector));
            ++failedForwards;
            return;
        }
        assertTrue(ok, "flush should be permissionless and succeed with compatible recipients");
        pendingHook = 0;
        feePaid[recipient] += fee;
        totalFeePaid += fee;
        if (toSink) sinkPaid += amount - fee;
        else poolRetained += amount - fee;
        assertEq(address(hook).balance, 0, "all stray ETH is distributed");
        ++successfulFlushes;
    }

    function routeSink(bool enabled, bool reject) external {
        sink.setRejects(reject);
        vm.prank(owner);
        pool.setFeeSink(enabled ? address(sink) : address(0));
    }

    function updateRecipient(uint256 recipientSeed) external {
        address recipient = recipients[recipientSeed % 3];
        vm.prank(owner);
        (bool ok, bytes memory result) = address(hook).call(abi.encodeCall(hook.updateFeeAddress, (recipient)));
        if (renounced) {
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(IMD6900PerpHook.FeeAddressIsRenounced.selector));
        } else {
            assertTrue(ok);
            assertEq(hook.feeAddress(), recipient);
        }
    }

    function renounce(bool asFeeRecipient) external {
        address caller = asFeeRecipient && !renounced ? hook.feeAddress() : owner;
        vm.prank(caller);
        (bool ok, bytes memory result) = address(hook).call(abi.encodeCall(hook.renounceFeeAddress, ()));
        if (renounced) {
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(IMD6900PerpHook.FeeAddressIsRenounced.selector));
        } else {
            assertTrue(ok);
            renounced = true;
        }
    }

    function unauthorizedRenounce(uint256 actorSeed) external {
        vm.prank(donors[actorSeed % 3]);
        (bool ok, bytes memory result) = address(hook).call(abi.encodeCall(hook.renounceFeeAddress, ()));
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(Ownable.Unauthorized.selector));
    }

    function payPool(uint256 actorSeed, uint256 amountSeed, bool throughAddFees) external {
        uint256 amount = bound(amountSeed, 0, 1 ether);
        bool toSink = throughAddFees && pool.feeSink() != address(0);
        bytes memory data = throughAddFees ? abi.encodeCall(pool.addFees, ()) : bytes("");
        vm.prank(donors[actorSeed % 3]);
        (bool ok, bytes memory result) = address(pool).call{value: amount}(data);
        if (toSink && sink.rejects()) {
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(RecordingFeeSink.SinkRejected.selector));
            ++failedForwards;
            return;
        }
        assertTrue(ok);
        totalSent += amount;
        if (toSink) sinkPaid += amount;
        else poolRetained += amount;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PerpsFeesInvariantTest is PerpsTestFixture {
    FeeSequenceHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new FeeSequenceHandler(pool, hook);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.flush.selector;
        selectors[2] = handler.routeSink.selector;
        selectors[3] = handler.updateRecipient.selector;
        selectors[4] = handler.renounce.selector;
        selectors[5] = handler.unauthorizedRenounce.selector;
        selectors[6] = handler.payPool.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_feeFlowsConserveEveryWeiAndReachOnlyTheCurrentRecipients() public view {
        assertEq(address(hook).balance, handler.pendingHook());
        assertEq(address(pool).balance, handler.poolRetained());
        assertEq(address(handler.sink()).balance, handler.sinkPaid());
        assertEq(handler.sink().received(), handler.sinkPaid());
        uint256 paid;
        for (uint256 i; i < 3; ++i) {
            address recipient = handler.recipients(i);
            assertEq(recipient.balance, handler.initialBalance(recipient) + handler.feePaid(recipient));
            paid += handler.feePaid(recipient);
        }
        assertEq(paid, handler.totalFeePaid());
        assertEq(
            address(hook).balance + address(pool).balance + address(handler.sink()).balance + paid, handler.totalSent()
        );
        assertEq(hook.feeAddressRenounced(), handler.renounced());
        if (handler.renounced()) assertEq(hook.feeAddress(), address(pool));
    }

    function test_HandlerReachesFailureRecoveryAndPermanentRenunciation() public {
        handler.deposit(0, 101);
        handler.routeSink(true, true);
        handler.flush(1);
        invariant_feeFlowsConserveEveryWeiAndReachOnlyTheCurrentRecipients();
        assertEq(handler.failedForwards(), 1);
        handler.routeSink(true, false);
        handler.updateRecipient(1);
        handler.flush(2);
        assertEq(handler.feePaid(handler.recipients(1)), 3);
        handler.renounce(true);
        handler.deposit(1, 100);
        handler.flush(0);
        handler.updateRecipient(2);
        handler.renounce(false);
        handler.unauthorizedRenounce(2);
        handler.payPool(0, 50, true);
        handler.payPool(0, 25, false);
        assertEq(handler.successfulFlushes(), 2);
        invariant_feeFlowsConserveEveryWeiAndReachOnlyTheCurrentRecipients();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FlushRoundingAndIdempotence(uint128 amount) public {
        vm.deal(address(this), amount);
        (bool ok,) = address(hook).call{value: amount}("");
        assertTrue(ok);
        uint256 ownerBefore = TEAM.balance;
        uint256 poolBefore = address(pool).balance;
        hook.flush();
        uint256 fee = TEAM.balance - ownerBefore;
        uint256 retained = address(pool).balance - poolBefore;
        assertEq(fee + retained, amount);
        assertLe(fee * 100, uint256(amount) * 3);
        assertLt(uint256(amount) * 3 - fee * 100, 100, "round down by less than one wei");
        hook.flush();
        assertEq(TEAM.balance, ownerBefore + fee);
        assertEq(address(pool).balance, poolBefore + retained);
        assertEq(address(hook).balance, 0);
    }

    function test_FlushRoundingEdges() public {
        testFuzz_FlushRoundingAndIdempotence(0);
        testFuzz_FlushRoundingAndIdempotence(1);
        testFuzz_FlushRoundingAndIdempotence(33);
        testFuzz_FlushRoundingAndIdempotence(34);
        testFuzz_FlushRoundingAndIdempotence(100);
        testFuzz_FlushRoundingAndIdempotence(type(uint128).max);
    }
}
