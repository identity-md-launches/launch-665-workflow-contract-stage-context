// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HauntedFixture} from "./utils/HauntedFixture.sol";
import {HauntedHook} from "../src/HauntedHook.sol";
import {HauntedVault} from "../src/HauntedVault.sol";
import {JackpotVault} from "../src/JackpotVault.sol";
import {CharityVault} from "../src/CharityVault.sol";
import {HauntedDeployment} from "../src/HauntedDeployment.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

contract RevisionTest is HauntedFixture {
    function test_zeroCooldownRejectedAtConstructionAndByAdmin() public {
        bytes memory reason = abi.encodeWithSelector(HauntedVault.InvalidCooldown.selector, 0, 30 days);
        vm.expectRevert(reason);
        new JackpotVault(owner, 300, 0);
        vm.expectRevert(reason);
        new CharityVault(owner, alice, 100, 0);
        vm.startPrank(owner);
        vm.expectRevert(reason);
        jackpot.setCooldown(0);
        vm.expectRevert(reason);
        charity.setCooldown(0);
        vm.stopPrank();
    }

    function test_minimumCooldownAtTimestampZeroAndBoundary() public {
        vm.startPrank(owner);
        jackpot.setCooldown(1);
        jackpot.grantRole(jackpot.PAYER_ROLE(), owner);
        vm.stopPrank();
        jackpot.fund{value: 10 ether}();
        vm.warp(0);
        vm.prank(owner);
        jackpot.payout(alice);
        assertEq(jackpot.releaseAvailableAt(), 1);
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.CooldownActive.selector, 1));
        vm.prank(owner);
        jackpot.payout(alice);
        vm.warp(1);
        vm.prank(owner);
        jackpot.payout(alice);
        assertEq(jackpot.releaseCount(), 2);
    }

    function test_selfRecipientCannotConsumeCooldownOrInflateReleased() public {
        jackpot.fund{value: 10 ether}();
        vm.prank(owner);
        hook.forceOutcome(HauntedHook.Outcome.MiniJackpot);
        vm.expectEmit(address(hook));
        emit HauntedHook.JackpotSkipped(
            poolId, address(jackpot), abi.encodeWithSelector(HauntedVault.SelfRecipient.selector)
        );
        swap(true, -1 ether, abi.encode(address(jackpot)));
        assertEq(jackpot.reserve(), 10 ether);
        assertEq(jackpot.totalReleased(), 0);
        assertEq(jackpot.releaseCount(), 0);
        assertEq(jackpot.lastReleaseAt(), 0);
        swap(true, -1 ether, abi.encode(alice));
        assertEq(alice.balance, 0.3 ether);
        vm.prank(owner);
        vm.expectRevert(HauntedVault.SelfRecipient.selector);
        charity.setCharity(address(charity));
    }

    function test_renounceClearsForcedOutcomeAndPendingOwner() public {
        vm.startPrank(owner);
        hook.forceOutcome(HauntedHook.Outcome.FreeSwap);
        hook.transferOwnership(bob);
        hook.renounceOwnership();
        vm.stopPrank();
        assertFalse(hook.forcedOutcomeActive());
        assertEq(hook.owner(), address(0));
        assertEq(hook.pendingOwner(), address(0));
        uint256 expected = expectedOut(true, 1 ether, 3000);
        assertEq(abs1(swap(true, -1 ether, abi.encode(alice))), expected);
    }

    function test_vaultCodeRequired() public {
        vm.expectRevert(abi.encodeWithSelector(HauntedHook.VaultHasNoCode.selector, alice));
        new HauntedHook(address(manager), address(token), owner, alice, address(charity));
        vm.expectRevert(abi.encodeWithSelector(HauntedHook.VaultHasNoCode.selector, bob));
        new HauntedHook(address(manager), address(token), owner, address(jackpot), bob);
    }

    function test_noncanonicalBeneficiarySkipsWithoutRevertingSwap() public {
        jackpot.fund{value: 10 ether}();
        vm.prank(owner);
        hook.forceOutcome(HauntedHook.Outcome.MiniJackpot);
        swap(true, -1 ether, abi.encode(type(uint256).max));
        assertEq(jackpot.totalReleased(), 0);
        assertEq(jackpot.releaseCount(), 0);
        assertEq(hook.swapCount(), 1);
    }

    function test_canonicalPoolCannotBeSquattedAtAnotherPriceOrSpacing() public {
        HauntedHook h = deployHook(address(manager), address(token), bob, address(jackpot), address(charity));
        PoolKey memory k = key;
        k.hooks = IHooks(address(h));
        bytes memory reason = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(h),
            IHooks.afterInitialize.selector,
            abi.encodeWithSelector(HauntedHook.InvalidPoolConfiguration.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        vm.expectRevert(reason);
        manager.initialize(k, SQRT_PRICE_1_1 + 1);
        k.tickSpacing = 1;
        vm.expectRevert(reason);
        manager.initialize(k, SQRT_PRICE_1_1);
        assertEq(h.hauntedPools(), 0);
        k.tickSpacing = 60;
        manager.initialize(k, SQRT_PRICE_1_1);
        assertEq(h.hauntedPools(), 1);
    }

    function test_bundleArbitraryOuterSaltMinesHookAndGrantsRoles() public {
        HauntedDeployment d = new HauntedDeployment{salt: bytes32(uint256(4))}(
            address(manager), address(token), owner, charityWallet, 300, 600, 100, 3600
        );
        HauntedHook h = d.hook();
        JackpotVault j = d.jackpotVault();
        CharityVault c = d.charityVault();
        assertEq(uint160(address(h)) & 0x3FFF, 0x10C0);
        assertEq(h.owner(), owner);
        assertTrue(j.hasRole(j.PAYER_ROLE(), address(h)));
        assertTrue(c.hasRole(c.SIGNALER_ROLE(), address(h)));
        _checkHandoff(j, address(d));
        _checkHandoff(c, address(d));
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(d)), 0);
        assertEq(token.balanceOf(address(h)), 0);
        _checkRuntime(address(d));
        _checkRuntime(address(h));
        _checkRuntime(address(h.game()));
        _checkRuntime(address(j));
        _checkRuntime(address(c));

        PoolKey memory k = h.game().poolKey();
        manager.initialize(k, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity{value: 2000 ether}(
            k, ModifyLiquidityParams(FULL_RANGE_LOWER, FULL_RANGE_UPPER, 1e21, 0), ""
        );
        j.fund{value: 10 ether}();
        c.fund{value: 10 ether}();
        vm.prank(owner);
        h.forceOutcome(HauntedHook.Outcome.MiniJackpot);
        swapAs(address(this), k, true, -1 ether, abi.encode(alice));
        assertEq(j.totalReleased(), 0.3 ether);
        vm.prank(owner);
        h.forceOutcome(HauntedHook.Outcome.CharitySignal);
        swapAs(address(this), k, true, -1 ether, abi.encode(alice));
        assertEq(c.totalReleased(), 0.1 ether);
    }

    function _checkHandoff(HauntedVault v, address bundle) private view {
        assertTrue(v.hasRole(v.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(v.hasRole(v.PAUSER_ROLE(), owner));
        assertFalse(v.hasRole(v.DEFAULT_ADMIN_ROLE(), bundle));
        assertFalse(v.hasRole(v.PAUSER_ROLE(), bundle));
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }
}
