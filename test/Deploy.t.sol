// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {HookSaltMiner} from "../src/HookSaltMiner.sol";
import {HauntedHook} from "../src/HauntedHook.sol";

/// @notice Calls the script's `deploy` directly with an explicit config; `run()` and the environment
/// are never touched here.
contract DeployTest is Test {
    Deploy internal script;
    address internal poolManager = makeAddr("poolManager");
    address internal owner = makeAddr("owner");
    address internal charityWallet = makeAddr("charity");

    function setUp() public {
        script = new Deploy();
    }

    function config() internal view returns (Deploy.Config memory) {
        return Deploy.Config({
            poolManager: poolManager,
            owner: owner,
            charity: charityWallet,
            jackpotBps: 300,
            jackpotCooldown: 10 minutes,
            charityBps: 100,
            charityCooldown: 1 hours
        });
    }

    function test_deployWiresEverything() public {
        Deploy.Deployment memory d = script.deploy(config());

        assertEq(d.token.balanceOf(address(script)), 10 ** 27, "token supply to deployer");
        assertEq(address(d.hook.poolManager()), poolManager);
        assertEq(address(d.hook.voidToken()), address(d.token));
        assertEq(address(d.hook.jackpotVault()), address(d.jackpotVault));
        assertEq(address(d.hook.charityVault()), address(d.charityVault));
        assertEq(d.hook.owner(), owner);
        assertEq(uint160(address(d.hook)) & 0x3FFF, 0x10C0, "hook flags");

        assertTrue(d.jackpotVault.hasRole(d.jackpotVault.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(d.jackpotVault.hasRole(d.jackpotVault.PAUSER_ROLE(), owner));
        assertTrue(d.jackpotVault.hasRole(d.jackpotVault.PAYER_ROLE(), address(d.hook)), "role granted atomically");
        assertEq(d.jackpotVault.releaseBps(), 300);
        assertEq(d.jackpotVault.cooldown(), 10 minutes);
        assertEq(d.charityVault.charity(), charityWallet);
        assertEq(d.charityVault.releaseBps(), 100);
        assertEq(d.charityVault.cooldown(), 1 hours);
    }

    function test_hookSaltMatchesInitCode() public {
        Deploy.Deployment memory d = script.deploy(config());
        bytes memory initCode =
            script.hookInitCode(poolManager, address(d.token), owner, address(d.jackpotVault), address(d.charityVault));
        assertEq(HookSaltMiner.predict(address(d.bundle), d.hookSalt, keccak256(initCode)), address(d.hook));
    }

    function test_mineHookSaltIsPure() public view {
        (bytes32 salt, address predicted) =
            script.mineHookSalt(address(0x1234), poolManager, address(0xA), owner, address(0xB), address(0xC));
        assertTrue(HookSaltMiner.hasExactFlags(predicted, HookSaltMiner.HAUNTED_HOOK_FLAGS));
        bytes memory initCode = script.hookInitCode(poolManager, address(0xA), owner, address(0xB), address(0xC));
        assertEq(HookSaltMiner.predict(address(0x1234), salt, keccak256(initCode)), predicted);
    }

    function test_deployRejectsBadVaultParams() public {
        Deploy.Config memory c = config();
        c.jackpotBps = 301;
        vm.expectRevert();
        script.deploy(c);
    }

    function test_hookWithoutVaultCodeReverts() public {
        vm.expectRevert(abi.encodeWithSelector(HauntedHook.VaultHasNoCode.selector, address(0xB)));
        new HauntedHook(poolManager, address(0xA), owner, address(0xB), address(0xC));
    }
}
