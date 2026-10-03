// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HauntedFixture} from "./utils/HauntedFixture.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {HauntedHook} from "../src/HauntedHook.sol";
import {HauntedVault} from "../src/HauntedVault.sol";
import {HookSaltMiner} from "../src/HookSaltMiner.sol";

contract OtherToken is ERC20 {
    constructor() ERC20("Other", "OTH") {
        _mint(msg.sender, 1e27);
    }
}

/// @dev A jackpot winner that tries to run a nested swap on the haunted pool from inside the payout.
contract ReentrantWinner {
    IPoolManager internal manager;
    PoolKey internal key;
    bytes public nestedRevert;

    constructor(IPoolManager m, PoolKey memory k) {
        manager = m;
        key = k;
    }

    receive() external payable {
        try manager.swap(key, SwapParams(true, -1, 4_295_128_740), "") {}
        catch (bytes memory reason) {
            nestedRevert = reason;
            revert("nested swap failed");
        }
    }
}

contract HauntedHookTest is HauntedFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int256 internal constant ONE_ETH_IN = -1 ether;

    function wrapped(bytes4 hookSelector, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookSelector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    // ------------------------------------------------------------------ construction and permissions

    function test_deploymentWiring() public view {
        assertEq(uint160(address(hook)) & 0x3FFF, 0x10C0);
        assertEq(hook.REQUIRED_FLAGS(), 0x10C0);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(address(hook.voidToken()), address(token));
        assertEq(address(hook.jackpotVault()), address(jackpot));
        assertEq(address(hook.charityVault()), address(charity));
        assertEq(hook.owner(), owner);
        assertEq(hook.burnBps(), 100);
        assertEq(hook.corruption(), 0);
        assertTrue(hook.haunted(poolId));
        assertEq(hook.hauntedPools(), 1);
        assertEq(lpFee(), 3000, "opening dynamic fee is 0.30%");
        assertFalse(hook.swapPending());
    }

    function test_permissionsMatchFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize && p.beforeSwap && p.afterSwap);
        assertFalse(
            p.beforeInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate || p.beforeSwapReturnDelta
                || p.afterSwapReturnDelta || p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta
        );
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(HauntedHook.ZeroAddress.selector);
        new HauntedHook(address(0), address(token), owner, address(jackpot), address(charity));
        vm.expectRevert(HauntedHook.ZeroAddress.selector);
        new HauntedHook(address(manager), address(0), owner, address(jackpot), address(charity));
        vm.expectRevert(HauntedHook.ZeroAddress.selector);
        new HauntedHook(address(manager), address(token), owner, address(0), address(charity));
        vm.expectRevert(HauntedHook.ZeroAddress.selector);
        new HauntedHook(address(manager), address(token), owner, address(jackpot), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new HauntedHook(address(manager), address(token), address(0), address(jackpot), address(charity));
    }

    function test_constructorRejectsUnflaggedAddress() public {
        vm.expectPartialRevert(HauntedHook.HookAddressNotValid.selector);
        new HauntedHook(address(manager), address(token), owner, address(jackpot), address(charity));
    }

    function test_onlyPoolManagerCallsCallbacks() public {
        SwapParams memory p = swapParams(true, ONE_ETH_IN);
        vm.expectRevert(HauntedHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(HauntedHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, p, BalanceDeltaLibrary.ZERO_DELTA, "");
        vm.expectRevert(HauntedHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    function test_unusedCallbacksRevert() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(0, 60, 1, 0);
        vm.startPrank(address(manager));
        vm.expectRevert(HauntedHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(HauntedHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(HauntedHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(
            address(this), key, lp, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, ""
        );
        vm.expectRevert(HauntedHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(HauntedHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(
            address(this), key, lp, BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA, ""
        );
        vm.expectRevert(HauntedHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(HauntedHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ afterInitialize

    function test_initializeRejectsStaticFee() public {
        PoolKey memory k = hauntedKey(TICK_SPACING);
        k.fee = 3000;
        vm.expectRevert(
            wrapped(IHooks.afterInitialize.selector, abi.encodeWithSelector(HauntedHook.PoolFeeNotDynamic.selector))
        );
        manager.initialize(k, SQRT_PRICE_1_1);
        assertFalse(hook.haunted(k.toId()));
    }

    function test_initializeRejectsForeignPair() public {
        OtherToken other = new OtherToken();
        PoolKey memory k = hauntedKey(TICK_SPACING);
        k.currency1 = Currency.wrap(address(other));
        vm.expectRevert(
            wrapped(IHooks.afterInitialize.selector, abi.encodeWithSelector(HauntedHook.UnsupportedPair.selector))
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_initializeRejectsVoidNotAsCurrency1() public {
        // Any pair whose currency0 is not native ETH is refused, even when VOID is in it.
        OtherToken other = new OtherToken();
        (address c0, address c1) =
            address(other) < address(token) ? (address(other), address(token)) : (address(token), address(other));
        PoolKey memory k = hauntedKey(TICK_SPACING);
        k.currency0 = Currency.wrap(c0);
        k.currency1 = Currency.wrap(c1);
        vm.expectRevert(
            wrapped(IHooks.afterInitialize.selector, abi.encodeWithSelector(HauntedHook.UnsupportedPair.selector))
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_secondHauntedPoolSharesState() public {
        PoolKey memory k2 = hauntedKey(10);
        vm.expectEmit(address(hook));
        emit HauntedHook.PoolHaunted(k2.toId(), address(this), SQRT_PRICE_1_1, 0);
        manager.initialize(k2, SQRT_PRICE_1_1);
        assertTrue(hook.haunted(k2.toId()));
        assertEq(hook.hauntedPools(), 2);
        (,,, uint24 fee2) = manager.getSlot0(k2.toId());
        assertEq(fee2, 3000);

        lpRouter.modifyLiquidity{value: 20 ether}(k2, ModifyLiquidityParams(-887_220, 887_220, 1e19, 0), "");
        vm.prank(owner);
        hook.forceOutcome(HauntedHook.Outcome.NormalTrade);
        swapAs(address(this), k2, true, -0.01 ether, "");
        swap(true, -0.01 ether, "");
        assertEq(hook.swapCount(), 2);
        assertEq(hook.corruption(), 2);
    }

    // ------------------------------------------------------------------ pure rules

    function testFuzz_outcomeForRollBands(uint256 roll, uint256 corruption) public view {
        roll = bound(roll, 0, 999);
        corruption = bound(corruption, 0, 100);
        HauntedHook.Outcome o = hook.outcomeForRoll(roll, corruption);
        uint256 band = 5 + corruption / 10;
        if (roll < band) assertEq(uint8(o), uint8(HauntedHook.Outcome.RealityCollapse));
        else if (roll < 600) assertEq(uint8(o), uint8(HauntedHook.Outcome.NormalTrade));
        else if (roll < 700) assertEq(uint8(o), uint8(HauntedHook.Outcome.FreeSwap));
        else if (roll < 800) assertEq(uint8(o), uint8(HauntedHook.Outcome.CorruptedFee));
        else if (roll < 880) assertEq(uint8(o), uint8(HauntedHook.Outcome.VoidBurn));
        else if (roll < 940) assertEq(uint8(o), uint8(HauntedHook.Outcome.LoreSignal));
        else if (roll < 970) assertEq(uint8(o), uint8(HauntedHook.Outcome.MiniJackpot));
        else assertEq(uint8(o), uint8(HauntedHook.Outcome.CharitySignal));
    }

    function test_collapseBandWidensWithCorruption() public view {
        assertEq(uint8(hook.outcomeForRoll(4, 0)), uint8(HauntedHook.Outcome.RealityCollapse));
        assertEq(uint8(hook.outcomeForRoll(5, 0)), uint8(HauntedHook.Outcome.NormalTrade));
        assertEq(uint8(hook.outcomeForRoll(14, 100)), uint8(HauntedHook.Outcome.RealityCollapse));
        assertEq(uint8(hook.outcomeForRoll(15, 100)), uint8(HauntedHook.Outcome.NormalTrade));
    }

    function testFuzz_feeForOutcomeBounded(uint8 outcomeRaw, uint256 corruption) public view {
        HauntedHook.Outcome o = HauntedHook.Outcome(bound(outcomeRaw, 0, 7));
        corruption = bound(corruption, 0, 100);
        uint24 fee = hook.feeForOutcome(o, corruption);
        assertLe(fee, 50_000);
        if (o == HauntedHook.Outcome.FreeSwap) {
            assertEq(fee, 0);
        } else if (o == HauntedHook.Outcome.RealityCollapse) {
            assertEq(fee, 50_000);
        } else if (o == HauntedHook.Outcome.CorruptedFee) {
            uint256 raw = 3000 + corruption * 500;
            assertEq(fee, raw > 50_000 ? 50_000 : raw);
            assertGe(fee, 3000);
        } else {
            assertEq(fee, 3000);
        }
    }

    function test_corruptedFeeMonotoneAndCapped() public view {
        uint24 prev;
        for (uint256 c; c <= 100; ++c) {
            uint24 f = hook.feeForOutcome(HauntedHook.Outcome.CorruptedFee, c);
            assertGe(f, prev);
            prev = f;
        }
        assertEq(hook.feeForOutcome(HauntedHook.Outcome.CorruptedFee, 94), 50_000);
        assertEq(hook.feeForOutcome(HauntedHook.Outcome.CorruptedFee, 93), 49_500);
        assertEq(hook.feeForOutcome(HauntedHook.Outcome.CorruptedFee, 1), 3500);
    }

    // ------------------------------------------------------------------ every outcome, forced

    function force(HauntedHook.Outcome o) internal {
        vm.prank(owner);
        hook.forceOutcome(o);
    }

    function test_forcedNormalTradeChargesBaseFee() public {
        force(HauntedHook.Outcome.NormalTrade);
        uint256 out = expectedOut(true, 1 ether, 3000);
        vm.expectEmit(address(hook));
        emit HauntedHook.NormalTrade(poolId, alice, 3000);
        vm.expectEmit(true, true, true, false, address(hook));
        emit HauntedHook.SwapResolved(poolId, alice, HauntedHook.Outcome.NormalTrade, 3000, 0, true, 1, 1);
        BalanceDelta d = swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(abs1(d), out, "0.30% fee applied");
        assertEq(abs0(d), 1 ether);
        assertEq(hook.corruption(), 1);
        assertEq(hook.swapCount(), 1);
        assertFalse(hook.swapPending());
    }

    function test_forcedFreeSwapChargesNothing() public {
        force(HauntedHook.Outcome.FreeSwap);
        uint256 outFree = expectedOut(true, 1 ether, 0);
        uint256 outNormal = expectedOut(true, 1 ether, 3000);
        assertGt(outFree, outNormal);
        vm.expectEmit(address(hook));
        emit HauntedHook.FreeSwap(poolId, alice);
        BalanceDelta d = swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(abs1(d), outFree, "no fee applied");
        assertEq(hook.corruption(), 1);
    }

    function test_forcedCorruptedFeeScalesWithCorruption() public {
        vm.prank(owner);
        hook.forceCorruption(10);
        force(HauntedHook.Outcome.CorruptedFee);
        uint24 fee = 3000 + 10 * 500;
        uint256 out = expectedOut(true, 1 ether, fee);
        vm.expectEmit(address(hook));
        emit HauntedHook.CorruptedFee(poolId, alice, fee, 15);
        BalanceDelta d = swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(abs1(d), out, "corrupted fee applied");
        assertEq(hook.corruption(), 15, "+5 corruption");
    }

    function test_corruptedFeeCapsAtFivePercent() public {
        vm.prank(owner);
        hook.forceCorruption(100);
        force(HauntedHook.Outcome.CorruptedFee);
        uint256 out = expectedOut(true, 1 ether, 50_000);
        BalanceDelta d = swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(abs1(d), out);
        assertEq(hook.corruption(), 100, "corruption stays capped");
    }

    function test_forcedBurnTakesFromHoard() public {
        token.approve(address(hook), type(uint256).max);
        vm.expectEmit(address(hook));
        emit HauntedHook.HoardFunded(address(this), 1_000 ether, 1_000 ether);
        hook.fundHoard(1_000 ether);
        force(HauntedHook.Outcome.VoidBurn);

        uint256 voidOut = expectedOut(true, 1 ether, 3000);
        uint256 expectedBurn = voidOut * 100 / 10_000; // 1% of the VOID moved, below the 1%-of-hoard cap
        assertLt(expectedBurn, 10 ether);
        vm.expectEmit(address(hook));
        emit HauntedHook.VoidBurned(poolId, alice, expectedBurn, expectedBurn);
        BalanceDelta d = swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(abs1(d), voidOut, "burn does not change the swap output");
        assertEq(hook.totalBurned(), expectedBurn);
        assertEq(hook.burnCount(), 1);
        assertEq(token.balanceOf(hook.DEAD()), expectedBurn);
        assertEq(hook.hoard(), 1_000 ether - expectedBurn);
    }

    function test_burnCappedAtOnePercentOfHoard() public {
        token.transfer(address(hook), 10 ether); // plain transfer also funds the hoard
        assertEq(hook.hoard(), 10 ether);
        force(HauntedHook.Outcome.VoidBurn);
        // 1% of a 100 ETH swap's VOID is ~1 VOID, far above 1% of a 10 VOID hoard (0.1).
        swap(true, -100 ether, abi.encode(alice));
        assertEq(hook.totalBurned(), 0.1 ether);
        assertEq(hook.hoard(), 9.9 ether);
    }

    function test_burnUsesVoidLegInBothDirections() public {
        token.transfer(address(hook), 1_000_000 ether);
        force(HauntedHook.Outcome.VoidBurn);
        BalanceDelta d = swap(false, -5 ether, abi.encode(alice)); // VOID in
        assertEq(abs1(d), 5 ether);
        assertEq(hook.totalBurned(), 0.05 ether, "1% of the 5 VOID input");
    }

    function test_burnSkippedWhenHoardEmpty() public {
        force(HauntedHook.Outcome.VoidBurn);
        vm.expectEmit(address(hook));
        emit HauntedHook.BurnSkipped(poolId, alice, 0);
        swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(hook.totalBurned(), 0);
        assertEq(hook.corruption(), 1);
    }

    function test_burnSkippedWhenBurnBpsZero() public {
        token.transfer(address(hook), 1_000 ether);
        vm.prank(owner);
        hook.setBurnBps(0);
        force(HauntedHook.Outcome.VoidBurn);
        vm.expectEmit(address(hook));
        emit HauntedHook.BurnSkipped(poolId, alice, 1_000 ether);
        swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(hook.hoard(), 1_000 ether);
    }

    function testFuzz_burnNeverExceedsCaps(uint256 hoardAmount, uint256 bps, uint256 swapIn) public {
        hoardAmount = bound(hoardAmount, 0, 1e24);
        bps = bound(bps, 0, 500);
        swapIn = bound(swapIn, 1e12, 50 ether);
        if (hoardAmount > 0) token.transfer(address(hook), hoardAmount);
        vm.prank(owner);
        hook.setBurnBps(bps);
        force(HauntedHook.Outcome.VoidBurn);
        uint256 voidOut = expectedOut(true, swapIn, 3000);
        swap(true, -int256(swapIn), abi.encode(alice));
        uint256 burned = hook.totalBurned();
        assertLe(burned, hoardAmount / 100, "<= 1% of hoard");
        assertLe(burned, voidOut * bps / 10_000, "<= burnBps of volume");
        uint256 expected = voidOut * bps / 10_000;
        if (expected > hoardAmount / 100) expected = hoardAmount / 100;
        assertEq(burned, expected);
        assertEq(token.balanceOf(hook.DEAD()), burned);
    }

    function test_forcedLoreCyclesFragments() public {
        force(HauntedHook.Outcome.LoreSignal);
        for (uint256 i; i < 14; ++i) {
            uint256 fragment = i % 13;
            vm.expectEmit(true, true, true, false, address(hook));
            emit HauntedHook.LoreSignal(poolId, alice, fragment, bytes32(0), 0);
            swap(true, -0.01 ether, abi.encode(alice));
            assertEq(hook.loreSignals(), i + 1);
            assertTrue(hook.loreUnlockedMask() & (1 << fragment) != 0);
        }
        assertEq(hook.loreUnlockedMask(), (1 << 13) - 1, "all fragments unlocked");
    }

    function test_forcedJackpotPaysSwapperFromHookData() public {
        jackpot.fund{value: 10 ether}();
        force(HauntedHook.Outcome.MiniJackpot);
        uint256 before = alice.balance;
        vm.expectEmit(address(hook));
        emit HauntedHook.MiniJackpot(poolId, alice, 0.3 ether);
        swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(alice.balance - before, 0.3 ether, "3% of the reserve to the named swapper");
        assertEq(jackpot.reserve(), 9.7 ether);
    }

    /// @dev Without hookData the beneficiary is the router. PoolSwapTest cannot receive ETH, so the
    /// vault's transfer fails, the hook records a skipped jackpot and the swap still completes.
    function test_jackpotFallsBackToRouterWithoutHookData() public {
        jackpot.fund{value: 10 ether}();
        force(HauntedHook.Outcome.MiniJackpot);
        vm.expectEmit(address(hook));
        emit HauntedHook.JackpotSkipped(
            poolId,
            address(swapRouter),
            abi.encodeWithSelector(HauntedVault.TransferFailed.selector, address(swapRouter), 0.3 ether)
        );
        swap(true, ONE_ETH_IN, "");
        assertEq(jackpot.reserve(), 10 ether);
        assertEq(jackpot.lastReleaseAt(), 0, "a failed payout does not consume the cooldown");
        assertEq(hook.swapCount(), 1);
    }

    function test_zeroHookDataAddressFallsBackToRouter() public {
        jackpot.fund{value: 10 ether}();
        force(HauntedHook.Outcome.MiniJackpot);
        vm.expectEmit(true, true, false, false, address(hook));
        emit HauntedHook.JackpotSkipped(poolId, address(swapRouter), "");
        swap(true, ONE_ETH_IN, abi.encode(address(0)));
    }

    function test_malformedHookDataFallsBackToRouter() public {
        jackpot.fund{value: 10 ether}();
        force(HauntedHook.Outcome.MiniJackpot);
        vm.expectEmit(true, true, false, false, address(hook));
        emit HauntedHook.JackpotSkipped(poolId, address(swapRouter), "");
        swap(true, ONE_ETH_IN, hex"deadbeef");
    }

    function test_jackpotSkippedWhenVaultEmpty() public {
        force(HauntedHook.Outcome.MiniJackpot);
        vm.expectEmit(address(hook));
        emit HauntedHook.JackpotSkipped(poolId, alice, abi.encodeWithSelector(HauntedVault.NothingToRelease.selector));
        swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(hook.swapCount(), 1, "swap still went through");
    }

    function test_jackpotSkippedOnCooldown() public {
        jackpot.fund{value: 10 ether}();
        force(HauntedHook.Outcome.MiniJackpot);
        swap(true, ONE_ETH_IN, abi.encode(alice));
        uint256 availableAt = block.timestamp + JACKPOT_COOLDOWN;
        vm.expectEmit(address(hook));
        emit HauntedHook.JackpotSkipped(
            poolId, bob, abi.encodeWithSelector(HauntedVault.CooldownActive.selector, availableAt)
        );
        swap(true, ONE_ETH_IN, abi.encode(bob));
        assertEq(bob.balance, 0);
        vm.warp(availableAt);
        swap(true, ONE_ETH_IN, abi.encode(bob));
        assertEq(bob.balance, 9.7 ether * 300 / 10_000);
    }

    function test_jackpotSkippedWhenPaused() public {
        jackpot.fund{value: 10 ether}();
        vm.prank(owner);
        jackpot.pause();
        force(HauntedHook.Outcome.MiniJackpot);
        vm.expectEmit(address(hook));
        emit HauntedHook.JackpotSkipped(poolId, alice, abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(jackpot.reserve(), 10 ether);
    }

    function test_jackpotSkippedWithoutRole() public {
        jackpot.fund{value: 10 ether}();
        bytes32 payer = jackpot.PAYER_ROLE();
        vm.prank(owner);
        jackpot.revokeRole(payer, address(hook));
        force(HauntedHook.Outcome.MiniJackpot);
        vm.expectEmit(address(hook));
        emit HauntedHook.JackpotSkipped(
            poolId,
            alice,
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(hook), jackpot.PAYER_ROLE()
            )
        );
        swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(jackpot.reserve(), 10 ether);
    }

    function test_forcedCharityDonates() public {
        charity.fund{value: 10 ether}();
        force(HauntedHook.Outcome.CharitySignal);
        vm.expectEmit(address(hook));
        emit HauntedHook.CharitySignal(poolId, alice, charityWallet, 0.1 ether);
        swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(charityWallet.balance, 0.1 ether, "1% of the reserve");
        assertEq(charity.reserve(), 9.9 ether);
    }

    function test_charitySkippedWhenEmptyOrCoolingDown() public {
        force(HauntedHook.Outcome.CharitySignal);
        vm.expectEmit(address(hook));
        emit HauntedHook.CharitySkipped(poolId, alice, abi.encodeWithSelector(HauntedVault.NothingToRelease.selector));
        swap(true, ONE_ETH_IN, abi.encode(alice));

        charity.fund{value: 10 ether}();
        swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(charityWallet.balance, 0.1 ether);
        vm.expectEmit(address(hook));
        emit HauntedHook.CharitySkipped(
            poolId,
            alice,
            abi.encodeWithSelector(HauntedVault.CooldownActive.selector, block.timestamp + CHARITY_COOLDOWN)
        );
        swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(charityWallet.balance, 0.1 ether);
    }

    function test_forcedCollapseResetsCorruptionAndChargesMaxFee() public {
        vm.prank(owner);
        hook.forceCorruption(42);
        force(HauntedHook.Outcome.RealityCollapse);
        uint256 out = expectedOut(true, 1 ether, 50_000);
        vm.expectEmit(address(hook));
        emit HauntedHook.RealityCollapse(poolId, alice, 42, 1);
        BalanceDelta d = swap(true, ONE_ETH_IN, abi.encode(alice));
        assertEq(abs1(d), out, "5% fee applied");
        assertEq(hook.corruption(), 0);
        assertEq(hook.collapseCount(), 1);
    }

    function test_exactOutputSwapAlsoResolves() public {
        force(HauntedHook.Outcome.NormalTrade);
        BalanceDelta d = swap(true, 1 ether, abi.encode(alice)); // exact 1 VOID out, ETH in
        assertEq(abs1(d), 1 ether);
        assertGt(abs0(d), 1 ether, "pays input plus fee");
        assertEq(hook.swapCount(), 1);
    }

    // ------------------------------------------------------------------ every outcome, unforced (steered draw)

    function test_everyOutcomeReachableFromTheDraw() public {
        token.transfer(address(hook), 1_000 ether);
        jackpot.fund{value: 10 ether}();
        charity.fund{value: 10 ether}();
        for (uint8 i; i < 8; ++i) {
            HauntedHook.Outcome target = HauntedHook.Outcome(i);
            steer(target, address(swapRouter), alice, -0.5 ether, true);
            uint256 corruptionBefore = hook.corruption();
            uint256 swapsBefore = hook.swapCount();
            vm.expectEmit(true, true, true, false, address(hook));
            emit HauntedHook.SwapResolved(poolId, alice, target, 0, 0, false, 0, 0);
            swap(true, -0.5 ether, abi.encode(alice));
            assertEq(hook.swapCount(), swapsBefore + 1);
            if (target == HauntedHook.Outcome.RealityCollapse) assertEq(hook.corruption(), 0);
            else if (target == HauntedHook.Outcome.CorruptedFee) assertEq(hook.corruption(), corruptionBefore + 5);
            else assertEq(hook.corruption(), corruptionBefore + 1);
            assertFalse(hook.forcedOutcomeActive());
        }
        assertEq(hook.collapseCount(), 1);
        assertEq(hook.loreSignals(), 1);
        assertEq(hook.burnCount(), 1);
        assertEq(jackpot.releaseCount(), 1);
        assertEq(charity.releaseCount(), 1);
    }

    function test_seedAdvancesEverySwap() public {
        bytes32 s0 = hook.seed();
        swap(true, -0.1 ether, "");
        bytes32 s1 = hook.seed();
        swap(true, -0.1 ether, "");
        assertTrue(s0 != s1 && s1 != hook.seed());
    }

    function testFuzz_randomSwapsStayWithinBounds(uint256 prevrandao, uint8 steps) public {
        token.transfer(address(hook), 1_000 ether);
        jackpot.fund{value: 5 ether}();
        charity.fund{value: 5 ether}();
        steps = uint8(bound(steps, 1, 24));
        for (uint256 i; i < steps; ++i) {
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode(prevrandao, i)))));
            bool zeroForOne = i % 3 != 0;
            swap(zeroForOne, -0.2 ether, abi.encode(alice));
            assertLe(hook.corruption(), 100);
            assertFalse(hook.swapPending());
        }
        assertEq(hook.swapCount(), steps);
        assertEq(hook.totalBurned(), token.balanceOf(hook.DEAD()));
        assertLe(hook.totalBurned(), 10 ether);
        assertEq(jackpot.reserve() + jackpot.totalReleased(), 5 ether);
        assertEq(charity.reserve() + charity.totalReleased(), 5 ether);
    }

    // ------------------------------------------------------------------ corruption dynamics

    function test_corruptionAccumulatesAndCaps() public {
        force(HauntedHook.Outcome.CorruptedFee);
        for (uint256 i; i < 25; ++i) {
            swap(true, -0.01 ether, "");
        }
        assertEq(hook.corruption(), 100, "25 x 5 capped at 100");
        force(HauntedHook.Outcome.NormalTrade);
        swap(true, -0.01 ether, "");
        assertEq(hook.corruption(), 100);
    }

    // ------------------------------------------------------------------ reentrancy

    function test_nestedSwapDuringPayoutIsRejected() public {
        ReentrantWinner w = new ReentrantWinner(manager, key);
        jackpot.fund{value: 10 ether}();
        force(HauntedHook.Outcome.MiniJackpot);
        vm.expectEmit(address(hook));
        emit HauntedHook.JackpotSkipped(
            poolId, address(w), abi.encodeWithSelector(HauntedVault.TransferFailed.selector, address(w), 0.3 ether)
        );
        swap(true, ONE_ETH_IN, abi.encode(address(w)));
        assertEq(jackpot.reserve(), 10 ether, "nothing left the vault");
        assertEq(address(w).balance, 0);
        assertEq(hook.swapCount(), 1);
        assertFalse(hook.swapPending());
    }

    function test_pendingGuardDirect() public {
        SwapParams memory p = swapParams(true, ONE_ETH_IN);
        vm.startPrank(address(manager));
        vm.expectRevert(HauntedHook.NoPendingSwap.selector);
        hook.afterSwap(address(this), key, p, BalanceDeltaLibrary.ZERO_DELTA, "");

        hook.beforeSwap(address(this), key, p, "");
        assertTrue(hook.swapPending());
        vm.expectRevert(HauntedHook.SwapAlreadyPending.selector);
        hook.beforeSwap(address(this), key, p, "");

        hook.afterSwap(address(this), key, p, BalanceDeltaLibrary.ZERO_DELTA, "");
        assertFalse(hook.swapPending());

        PoolKey memory foreign = hauntedKey(1);
        vm.expectRevert(HauntedHook.PoolNotHaunted.selector);
        hook.beforeSwap(address(this), foreign, p, "");
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ admin controls

    function test_adminControlsAreOwnerOnly() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.forceOutcome(HauntedHook.Outcome.FreeSwap);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.clearForcedOutcome();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.forceCorruption(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.setBurnBps(1);
        vm.stopPrank();
    }

    function test_forceAndClearOutcome() public {
        vm.startPrank(owner);
        vm.expectEmit(address(hook));
        emit HauntedHook.OutcomeForced(HauntedHook.Outcome.FreeSwap, true);
        hook.forceOutcome(HauntedHook.Outcome.FreeSwap);
        assertTrue(hook.forcedOutcomeActive());
        assertEq(uint8(hook.forcedOutcome()), uint8(HauntedHook.Outcome.FreeSwap));
        vm.expectEmit(address(hook));
        emit HauntedHook.OutcomeForced(HauntedHook.Outcome.FreeSwap, false);
        hook.clearForcedOutcome();
        assertFalse(hook.forcedOutcomeActive());
        vm.stopPrank();
    }

    function test_setBurnBpsBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(HauntedHook.InvalidBurnBps.selector, 501, 500));
        hook.setBurnBps(501);
        vm.expectEmit(address(hook));
        emit HauntedHook.BurnBpsUpdated(100, 500);
        hook.setBurnBps(500);
        vm.expectRevert(abi.encodeWithSelector(HauntedHook.InvalidCorruption.selector, 101, 100));
        hook.forceCorruption(101);
        hook.forceCorruption(100);
        vm.stopPrank();
        assertEq(hook.corruption(), 100);
    }

    function test_ownershipIsTwoStep() public {
        vm.prank(owner);
        hook.transferOwnership(bob);
        assertEq(hook.owner(), owner);
        assertEq(hook.pendingOwner(), bob);
        vm.prank(bob);
        hook.acceptOwnership();
        assertEq(hook.owner(), bob);
    }

    function test_hookNeverSendsVoidAnywhereButDead() public {
        token.transfer(address(hook), 100 ether);
        string[3] memory sigs = ["withdraw(uint256)", "rescue(address,uint256)", "sweep(address)"];
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(hook).call(abi.encodeWithSignature(sigs[i], owner, uint256(1 ether)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(hook.hoard(), 100 ether);
    }
}
