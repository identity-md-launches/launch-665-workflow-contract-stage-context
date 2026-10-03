// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookSaltMiner} from "../src/HookSaltMiner.sol";

contract Probe {
    uint256 public immutable value;

    constructor(uint256 v) {
        value = v;
    }
}

contract HookSaltMinerTest is Test {
    function test_flagsConstant() public pure {
        assertEq(uint256(HookSaltMiner.HAUNTED_HOOK_FLAGS), 0x10C0);
        assertEq(uint256(HookSaltMiner.ALL_HOOK_MASK), 0x3FFF);
    }

    function testFuzz_predictMatchesCreate2(uint256 v, bytes32 salt) public {
        bytes memory initCode = abi.encodePacked(type(Probe).creationCode, abi.encode(v));
        address predicted = HookSaltMiner.predict(address(this), salt, keccak256(initCode));
        Probe p = new Probe{salt: salt}(v);
        assertEq(address(p), predicted);
    }

    function testFuzz_hasExactFlags(uint160 raw, uint16 flags) public pure {
        flags = uint16(bound(flags, 0, 0x3FFF));
        address a = address((raw & ~HookSaltMiner.ALL_HOOK_MASK) | uint160(flags));
        assertTrue(HookSaltMiner.hasExactFlags(a, flags));
        assertEq(HookSaltMiner.hasExactFlags(a, uint160(flags) ^ 1), false);
    }

    function test_mineFindsExactFlags() public {
        bytes memory initCode = abi.encodePacked(type(Probe).creationCode, abi.encode(uint256(7)));
        (bytes32 salt, address predicted) =
            HookSaltMiner.mine(address(this), keccak256(initCode), HookSaltMiner.HAUNTED_HOOK_FLAGS, 0, 1_000_000);
        assertTrue(HookSaltMiner.hasExactFlags(predicted, HookSaltMiner.HAUNTED_HOOK_FLAGS));
        Probe p = new Probe{salt: salt}(7);
        assertEq(address(p), predicted);
        assertEq(uint160(address(p)) & 0x3FFF, 0x10C0);
    }

    function mineExternal(uint256 start, uint256 attempts) external pure returns (bytes32, address) {
        return HookSaltMiner.mine(address(0x1234), keccak256("x"), HookSaltMiner.HAUNTED_HOOK_FLAGS, start, attempts);
    }

    function test_mineRevertsWhenBudgetExhausted() public {
        vm.expectRevert(abi.encodeWithSelector(HookSaltMiner.SaltNotFound.selector, 0, 1));
        this.mineExternal(0, 1);
    }
}
