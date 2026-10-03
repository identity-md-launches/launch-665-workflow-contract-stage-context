// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Haunted VOID");
        assertEq(token.symbol(), "VOID");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToDeployer() public view {
        assertEq(token.SUPPLY(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(this)), 10 ** 27);
    }

    function test_transferMovesExactAmount() public {
        address to = makeAddr("to");
        assertTrue(token.transfer(to, 1 ether));
        assertEq(token.balanceOf(to), 1 ether);
        assertEq(token.balanceOf(address(this)), 10 ** 27 - 1 ether);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, token.totalSupply());
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(address(this)), token.totalSupply());
    }

    function test_transferAboveBalanceReverts() public {
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert();
        token.transfer(address(this), 1);
    }

    function test_noMintOrAdminSelectors() public {
        string[6] memory sigs = [
            "mint(address,uint256)",
            "burn(uint256)",
            "owner()",
            "pause()",
            "transferOwnership(address)",
            "setFee(uint256)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], address(this), uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), 10 ** 27);
    }
}
