// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/libraries/Hooks.sol";

/// @title HookSaltMiner
/// @notice Pure helpers to find a CREATE2 salt whose resulting address carries exactly the Uniswap v4
/// permission bits the HauntedHook declares. Used by the deploy script and the tests; the network's
/// deployer must do the same for the launch salt, because the PoolManager reads permissions from the
/// address and the hook constructor refuses an address with the wrong bits.
library HookSaltMiner {
    /// @notice The low 14 bits of a hook address encode its permissions.
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    /// @notice The HauntedHook permission bits: afterInitialize | beforeSwap | afterSwap = 0x10C0.
    uint160 internal constant HAUNTED_HOOK_FLAGS =
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

    error SaltNotFound(uint256 start, uint256 attempts);

    /// @notice CREATE2 address prediction: keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))[12:].
    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @notice True when `hook` has exactly the permission bits in `flags`.
    function hasExactFlags(address hook, uint160 flags) internal pure returns (bool) {
        return uint160(hook) & ALL_HOOK_MASK == flags;
    }

    /// @notice Scans salts `start, start+1, ...` (at most `maxAttempts`) for one whose CREATE2
    /// address from `deployer` with `initCodeHash` has exactly `flags` in its low 14 bits.
    /// @dev Expected attempts: 2^14 = 16,384. Off-chain or in a test this is cheap; it is not
    /// meant to run inside a transaction.
    function mine(address deployer, bytes32 initCodeHash, uint160 flags, uint256 start, uint256 maxAttempts)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < maxAttempts; ++i) {
            salt = bytes32(start + i);
            predicted = predict(deployer, salt, initCodeHash);
            if (hasExactFlags(predicted, flags)) return (salt, predicted);
        }
        revert SaltNotFound(start, maxAttempts);
    }
}
