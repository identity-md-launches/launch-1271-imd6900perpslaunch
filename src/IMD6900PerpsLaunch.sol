// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IMD6900PerpHook} from "./IMD6900PerpHook.sol";
import {IMD6900PerpPool} from "./IMD6900PerpPool.sol";

/// @title IMD6900PerpsLaunch - IMD6900's perps hook and pool, deployed in one constructor
/// @notice What the IMD swarm launches on Robinhood Chain (evm_contracts): constructor arguments only, nothing called
///         after. Uniswap v4 reads a hook's permissions from the low 14 bits of its address, so the hook must sit at
///         a mined address; IMD deploys this from its own deployer, which nobody can mine for in advance, so this
///         constructor mines it: it tries CREATE2 salts from itself until the hook's address carries exactly the
///         hook's flags, then creates the hook there. It creates the pool first (the hook names it), wires the pool
///         to the hook and hands the pool to `owner`; the hook is born owned by `owner`. It calls nothing that existed
///         before it, so it deploys the same way on a fresh chain.
contract IMD6900PerpsLaunch {
    /// @dev beforeInitialize, beforeAddLiquidity, beforeRemoveLiquidity, beforeSwap, afterSwap: nothing that would cost
    ///      the pool Uniswap's automatic routing (no return deltas, no dynamic fee)
    uint160 public constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
    /// @dev Bound the search so mining plus deployment fits the transaction budget. A rare miss reverts NoSalt;
    ///      admission must simulate the exact factory address and salt, then use a new launch number on a miss.
    uint256 internal constant MAX_TRIES = 134_144;

    IMD6900PerpPool public immutable pool;
    IMD6900PerpHook public immutable hook;
    bytes32 public immutable salt;

    error NoSalt();
    error BadHook();

    /// @param poolManager Uniswap v4's PoolManager on Robinhood Chain
    /// @param poolFee     the pool's static fee, hundredths of a bip (10000 = 1%), the hook's too
    /// @param owner       who runs the pool and the hook (the team's wallet, then its timelock)
    /// @param feeAddress  the hook's fee address (3% of any ETH it forwards)
    constructor(IPoolManager poolManager, uint24 poolFee, address owner, address feeAddress) {
        IMD6900PerpPool p = new IMD6900PerpPool(poolManager, poolFee, address(this));
        bytes memory init = abi.encodePacked(
            type(IMD6900PerpHook).creationCode, abi.encode(poolManager, address(p), feeAddress, owner, poolFee)
        );
        bytes32 s = _mine(keccak256(init));
        address h;
        assembly ("memory-safe") {
            h := create2(0, add(init, 0x20), mload(init), s)
        }
        if (h == address(0) || uint160(h) & Hooks.ALL_HOOK_MASK != FLAGS) revert BadHook();
        p.setHook(h);
        p.transferOwnership(owner);
        pool = p;
        hook = IMD6900PerpHook(payable(h));
        salt = s;
    }

    /// @dev The first salt whose CREATE2 address from here carries exactly {FLAGS} in its low 14 bits
    function _mine(bytes32 initHash) internal view returns (bytes32 s) {
        uint256 flags = FLAGS;
        bool found;
        assembly ("memory-safe") {
            // Temporarily use 0x00..0x5f for the CREATE2 preimage. Restore the free-memory pointer before leaving;
            // the zero slot at 0x60 is untouched. This avoids pointer arithmetic on every hash.
            let free := mload(0x40)
            mstore(0, address())
            mstore8(11, 0xff)
            mstore(0x40, initHash)
            // Check eight consecutive salts per batch, with one branch per batch rather than per hash.
            for { let i := 0 } lt(i, MAX_TRIES) { i := add(i, 8) } {
                mstore(0x20, i)
                let hit := eq(and(keccak256(11, 85), 0x3fff), flags)
                mstore(0x20, add(i, 1))
                hit := or(hit, eq(and(keccak256(11, 85), 0x3fff), flags))
                mstore(0x20, add(i, 2))
                hit := or(hit, eq(and(keccak256(11, 85), 0x3fff), flags))
                mstore(0x20, add(i, 3))
                hit := or(hit, eq(and(keccak256(11, 85), 0x3fff), flags))
                mstore(0x20, add(i, 4))
                hit := or(hit, eq(and(keccak256(11, 85), 0x3fff), flags))
                mstore(0x20, add(i, 5))
                hit := or(hit, eq(and(keccak256(11, 85), 0x3fff), flags))
                mstore(0x20, add(i, 6))
                hit := or(hit, eq(and(keccak256(11, 85), 0x3fff), flags))
                mstore(0x20, add(i, 7))
                hit := or(hit, eq(and(keccak256(11, 85), 0x3fff), flags))
                if hit {
                    // Only the winning batch is searched again, to preserve the first matching salt.
                    for { s := i } 1 { s := add(s, 1) } {
                        mstore(0x20, s)
                        if eq(and(keccak256(11, 85), 0x3fff), flags) { break }
                    }
                    found := 1
                    break
                }
            }
            mstore(0x40, free)
        }
        if (!found) revert NoSalt();
    }
}
