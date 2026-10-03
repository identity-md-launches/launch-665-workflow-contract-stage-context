// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HauntedFixture} from "./utils/HauntedFixture.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {HauntedHook} from "../src/HauntedHook.sol";
import {HauntedVault} from "../src/HauntedVault.sol";

/// @dev A jackpot winner that swaps on a *different* haunted pool from inside the payout.
contract CrossPoolReentrantWinner {
    IPoolManager internal manager;
    PoolKey internal otherKey;
    bytes public nestedRevert;

    constructor(IPoolManager m, PoolKey memory k) {
        manager = m;
        otherKey = k;
    }

    receive() external payable {
        try manager.swap(otherKey, SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1), "") {}
        catch (bytes memory reason) {
            nestedRevert = reason;
            revert("nested swap failed");
        }
    }
}

/// @notice Inputs the hook did not obviously consider: malformed and hostile beneficiaries, exact
/// output swaps in both directions, dust volumes, forced-state persistence, ownership hand-over,
/// cross-pool re-entry, and an oracle check that the fee actually charged is the outcome's fee.
contract HauntedHookEdgeTest is HauntedFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function wrapped(bytes4 hookSelector, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookSelector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function force(HauntedHook.Outcome o) internal {
        vm.prank(owner);
        hook.forceOutcome(o);
    }

    /// @dev Exact-output counterpart of the fixture's `expectedOut`: the input (plus fee) a single-step
    /// swap pays for `amountOut` at the current pool state and the given fee.
    function expectedIn(bool zeroForOne, uint256 amountOut, uint24 fee) internal view returns (uint256) {
        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        uint128 liquidity = manager.getLiquidity(poolId);
        uint160 target = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (, uint256 amountIn,, uint256 feeAmount) =
            SwapMath.computeSwapStep(sqrtP, target, liquidity, int256(amountOut), fee);
        return amountIn + feeAmount;
    }

    // ------------------------------------------------------------------ fee oracle over every outcome

    /// forge-config: default.fuzz.runs = 512
    /// @dev For every outcome, corruption level, direction and exact-input amount, the output equals
    /// what the Uniswap math yields at `feeForOutcome`, and the pool's stored fee is untouched.
    function testFuzz_exactInputFeeMatchesOutcome(uint8 outcomeRaw, uint256 corruption, uint256 amountIn, bool z4o)
        public
    {
        HauntedHook.Outcome o = HauntedHook.Outcome(bound(outcomeRaw, 0, 7));
        corruption = bound(corruption, 0, 100);
        amountIn = bound(amountIn, 1e9, 50 ether);
        vm.startPrank(owner);
        hook.forceCorruption(corruption);
        hook.forceOutcome(o);
        vm.stopPrank();

        uint24 fee = hook.feeForOutcome(o, corruption);
        uint256 out = expectedOut(z4o, amountIn, fee);
        BalanceDelta d = swap(z4o, -int256(amountIn), abi.encode(alice));
        uint256 paid = z4o ? abs0(d) : abs1(d);
        uint256 received = z4o ? abs1(d) : abs0(d);
        assertEq(paid, amountIn, "exact input paid in full");
        assertEq(received, out, "output matches the outcome's fee");
        assertEq(lpFee(), 3000, "the stored dynamic fee is never rewritten by a swap");
        assertFalse(hook.swapPending());
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_exactOutputFeeMatchesOutcome(uint8 outcomeRaw, uint256 corruption, uint256 amountOut, bool z4o)
        public
    {
        HauntedHook.Outcome o = HauntedHook.Outcome(bound(outcomeRaw, 0, 7));
        corruption = bound(corruption, 0, 100);
        amountOut = bound(amountOut, 1e9, 50 ether);
        vm.startPrank(owner);
        hook.forceCorruption(corruption);
        hook.forceOutcome(o);
        vm.stopPrank();

        uint24 fee = hook.feeForOutcome(o, corruption);
        uint256 expectedPaid = expectedIn(z4o, amountOut, fee);
        BalanceDelta d = swap(z4o, int256(amountOut), abi.encode(alice));
        uint256 paid = z4o ? abs0(d) : abs1(d);
        uint256 received = z4o ? abs1(d) : abs0(d);
        assertEq(received, amountOut, "exact output received in full");
        assertEq(paid, expectedPaid, "input matches the outcome's fee");
        assertEq(hook.swapCount(), 1);
    }

    function test_freeSwapInReverseDirectionChargesNothing() public {
        force(HauntedHook.Outcome.FreeSwap);
        uint256 outFree = expectedOut(false, 3 ether, 0);
        uint256 outNormal = expectedOut(false, 3 ether, 3000);
        assertGt(outFree, outNormal);
        BalanceDelta d = swap(false, -3 ether, abi.encode(alice));
        assertEq(abs0(d), outFree, "ETH out at zero fee");
        assertEq(abs1(d), 3 ether);
    }

    function test_collapseInReverseDirectionChargesFivePercent() public {
        force(HauntedHook.Outcome.RealityCollapse);
        uint256 out = expectedOut(false, 3 ether, 50_000);
        BalanceDelta d = swap(false, -3 ether, abi.encode(alice));
        assertEq(abs0(d), out);
        assertEq(hook.collapseCount(), 1);
    }

    // ------------------------------------------------------------------ beneficiary edge inputs

    function test_hookDataWithDirtyUpperBitsRevertsTheSwap() public {
        // 32 bytes that are not a clean address: abi.decode refuses it, so the swap reverts in
        // beforeSwap instead of silently paying a mangled address. Only the sender's own swap fails.
        bytes memory dirty = abi.encodePacked(bytes32(uint256(uint160(alice)) | (uint256(1) << 200)));
        assertEq(dirty.length, 32);
        vm.expectRevert(wrapped(IHooks.beforeSwap.selector, ""));
        swap(true, -1 ether, dirty);
        assertEq(hook.swapCount(), 0);
        assertFalse(hook.swapPending(), "a reverted swap leaves nothing pending");
    }

    function test_hookDataOfTwoWordsFallsBackToRouter() public {
        jackpot.fund{value: 10 ether}();
        force(HauntedHook.Outcome.MiniJackpot);
        vm.expectEmit(true, true, false, false, address(hook));
        emit HauntedHook.JackpotSkipped(poolId, address(swapRouter), "");
        swap(true, -1 ether, abi.encode(alice, bob));
        assertEq(alice.balance, 0);
        assertEq(bob.balance, 0);
    }

    function test_hookDataOfOneByteFallsBackToRouter() public {
        force(HauntedHook.Outcome.NormalTrade);
        vm.expectEmit(address(hook));
        emit HauntedHook.NormalTrade(poolId, address(swapRouter), 3000);
        swap(true, -1 ether, hex"01");
    }

    function test_beneficiaryNamingTheHookIsSkippedAndTheHookHoldsNoEth() public {
        jackpot.fund{value: 10 ether}();
        force(HauntedHook.Outcome.MiniJackpot);
        vm.expectEmit(address(hook));
        emit HauntedHook.JackpotSkipped(
            poolId,
            address(hook),
            abi.encodeWithSelector(HauntedVault.TransferFailed.selector, address(hook), 0.3 ether)
        );
        swap(true, -1 ether, abi.encode(address(hook)));
        assertEq(address(hook).balance, 0, "the hook never holds ETH");
        assertEq(jackpot.reserve(), 10 ether);
        assertEq(jackpot.lastReleaseAt(), 0, "a failed payout does not burn the cooldown");
    }

    function test_beneficiaryNamingThePoolManagerIsSkipped() public {
        jackpot.fund{value: 10 ether}();
        uint256 managerBalance = address(manager).balance;
        force(HauntedHook.Outcome.MiniJackpot);
        vm.expectEmit(address(hook));
        emit HauntedHook.JackpotSkipped(
            poolId,
            address(manager),
            abi.encodeWithSelector(HauntedVault.TransferFailed.selector, address(manager), 0.3 ether)
        );
        swap(true, -1 ether, abi.encode(address(manager)));
        assertEq(address(manager).balance, managerBalance + 1 ether, "only the swap's own ETH reached the manager");
        assertEq(jackpot.reserve(), 10 ether);
    }

    // ------------------------------------------------------------------ dust and caps on burns

    function test_burnRoundsDownToSkipOnDustVolume() public {
        token.transfer(address(hook), 1_000 ether);
        force(HauntedHook.Outcome.VoidBurn);
        // 50 wei of VOID in: 50 * 100 / 10_000 == 0, so the burn is skipped even with a full hoard.
        vm.expectEmit(address(hook));
        emit HauntedHook.BurnSkipped(poolId, alice, 1_000 ether);
        BalanceDelta d = swap(false, -50, abi.encode(alice));
        assertEq(abs1(d), 50);
        assertEq(hook.totalBurned(), 0);
        assertEq(hook.burnCount(), 0);
        assertEq(hook.corruption(), 1, "a skipped burn still corrupts");
    }

    function test_maxBurnBpsStillBoundedByHoardShare() public {
        token.transfer(address(hook), 10 ether);
        vm.prank(owner);
        hook.setBurnBps(500);
        force(HauntedHook.Outcome.VoidBurn);
        uint256 voidOut = expectedOut(true, 10 ether, 3000);
        assertGt(voidOut * 500 / 10_000, 0.1 ether, "5% of volume exceeds 1% of the hoard");
        swap(true, -10 ether, abi.encode(alice));
        assertEq(hook.totalBurned(), 0.1 ether, "capped at 1% of the hoard");
        assertEq(hook.burnAmountFor(voidOut), 0.099 ether, "quote follows the shrunken hoard");
    }

    function test_fundHoardWithoutApprovalReverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(hook), 0, 1 ether)
        );
        hook.fundHoard(1 ether);
        assertEq(hook.hoard(), 0);
    }

    function test_fundHoardAboveBalanceReverts() public {
        vm.startPrank(alice);
        token.approve(address(hook), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        hook.fundHoard(1 ether);
        vm.stopPrank();
    }

    function test_fundHoardZeroIsHarmless() public {
        token.approve(address(hook), 0);
        vm.expectEmit(address(hook));
        emit HauntedHook.HoardFunded(address(this), 0, 0);
        hook.fundHoard(0);
    }

    // ------------------------------------------------------------------ vault outcomes under failure

    function test_jackpotWhilePausedStillCorruptsAndKeepsCooldownFree() public {
        jackpot.fund{value: 10 ether}();
        vm.prank(owner);
        jackpot.pause();
        force(HauntedHook.Outcome.MiniJackpot);
        swap(true, -1 ether, abi.encode(alice));
        assertEq(hook.corruption(), 1);
        assertEq(jackpot.lastReleaseAt(), 0);
        // Unpaused: the very next jackpot pays, no cooldown was consumed by the skipped one.
        vm.prank(owner);
        jackpot.unpause();
        swap(true, -1 ether, abi.encode(alice));
        assertEq(alice.balance, 0.3 ether);
    }

    function test_charitySkippedWithoutRoleAndWhenPaused() public {
        charity.fund{value: 10 ether}();
        bytes32 signaler = charity.SIGNALER_ROLE();
        vm.prank(owner);
        charity.revokeRole(signaler, address(hook));
        force(HauntedHook.Outcome.CharitySignal);
        vm.expectEmit(address(hook));
        emit HauntedHook.CharitySkipped(
            poolId,
            alice,
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(hook), signaler)
        );
        swap(true, -1 ether, abi.encode(alice));

        vm.startPrank(owner);
        charity.grantRole(signaler, address(hook));
        charity.pause();
        vm.stopPrank();
        vm.expectEmit(address(hook));
        emit HauntedHook.CharitySkipped(poolId, alice, abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        swap(true, -1 ether, abi.encode(alice));
        assertEq(charityWallet.balance, 0);
        assertEq(hook.corruption(), 2);
    }

    function test_charityRecipientIsReadAtSwapTime() public {
        charity.fund{value: 10 ether}();
        vm.prank(owner);
        charity.setCharity(bob);
        force(HauntedHook.Outcome.CharitySignal);
        vm.expectEmit(address(hook));
        emit HauntedHook.CharitySignal(poolId, alice, bob, 0.1 ether);
        swap(true, -1 ether, abi.encode(alice));
        assertEq(bob.balance, 0.1 ether);
        assertEq(charityWallet.balance, 0);
    }

    // ------------------------------------------------------------------ forced state and the seed

    function test_forcedOutcomePersistsUntilClearedAndClearingRestoresTheDraw() public {
        force(HauntedHook.Outcome.FreeSwap);
        for (uint256 i; i < 3; ++i) {
            vm.expectEmit(address(hook));
            emit HauntedHook.FreeSwap(poolId, alice);
            swap(true, -0.1 ether, abi.encode(alice));
        }
        vm.prank(owner);
        hook.clearForcedOutcome();
        // Steer the draw to a normal trade and check the event says it was not forced.
        steer(HauntedHook.Outcome.NormalTrade, address(swapRouter), alice, -0.1 ether, true);
        vm.recordLogs();
        swap(true, -0.1 ether, abi.encode(alice));
        (,, bool forced,, uint256 index) = lastSwapResolved();
        assertFalse(forced);
        assertEq(index, 4);
    }

    function test_seedAdvancesEvenWhenForced() public {
        force(HauntedHook.Outcome.NormalTrade);
        bytes32 s0 = hook.seed();
        swap(true, -0.1 ether, "");
        assertTrue(hook.seed() != s0, "forcing does not freeze the seed");
    }

    function test_collapseAtZeroCorruptionIsRecorded() public {
        force(HauntedHook.Outcome.RealityCollapse);
        vm.expectEmit(address(hook));
        emit HauntedHook.RealityCollapse(poolId, alice, 0, 1);
        swap(true, -0.1 ether, abi.encode(alice));
        assertEq(hook.corruption(), 0);
        assertEq(hook.collapseCount(), 1);
        swap(true, -0.1 ether, abi.encode(alice));
        assertEq(hook.collapseCount(), 2, "collapses keep counting while forced");
    }

    function testFuzz_forcedCorruptionThenCorruptedSwapCaps(uint256 c) public {
        c = bound(c, 0, 100);
        vm.prank(owner);
        hook.forceCorruption(c);
        force(HauntedHook.Outcome.CorruptedFee);
        swap(true, -0.1 ether, abi.encode(alice));
        uint256 expected = c + 5 > 100 ? 100 : c + 5;
        assertEq(hook.corruption(), expected);
    }

    function test_swapResolvedIndexIsSequentialAcrossOutcomes() public {
        force(HauntedHook.Outcome.LoreSignal);
        for (uint256 i = 1; i <= 3; ++i) {
            vm.recordLogs();
            swap(i % 2 == 0, -0.1 ether, abi.encode(alice));
            (uint24 fee,, bool forced, uint256 corruption, uint256 index) = lastSwapResolved();
            assertEq(index, i);
            assertEq(fee, 3000);
            assertTrue(forced);
            assertEq(corruption, i);
        }
        assertEq(hook.swapCount(), 3);
    }

    /// @dev Decodes the non-indexed fields of the last SwapResolved event recorded.
    function lastSwapResolved()
        internal
        returns (uint24 fee, uint256 roll, bool forced, uint256 corruption, uint256 swapIndex)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = HauntedHook.SwapResolved.selector;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) {
                (fee, roll, forced, corruption, swapIndex) =
                    abi.decode(logs[i].data, (uint24, uint256, bool, uint256, uint256));
                found = true;
            }
        }
        assertTrue(found, "SwapResolved not emitted");
    }

    // ------------------------------------------------------------------ ownership hand-over

    function test_pendingOwnerHasNoControlUntilAccepted() public {
        vm.prank(owner);
        hook.transferOwnership(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        hook.forceOutcome(HauntedHook.Outcome.FreeSwap);
        vm.prank(owner);
        hook.forceOutcome(HauntedHook.Outcome.FreeSwap);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.acceptOwnership();
        vm.prank(bob);
        hook.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        hook.clearForcedOutcome();
        vm.prank(bob);
        hook.clearForcedOutcome();
        assertFalse(hook.forcedOutcomeActive());
    }

    function test_renouncedOwnershipLocksControlsButSwapsContinue() public {
        vm.prank(owner);
        hook.renounceOwnership();
        assertEq(hook.owner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        hook.setBurnBps(0);
        swap(true, -0.1 ether, abi.encode(alice));
        assertEq(hook.swapCount(), 1);
    }

    // ------------------------------------------------------------------ cross-pool re-entry

    function test_nestedSwapOnAnotherHauntedPoolDuringPayoutIsRejected() public {
        PoolKey memory k2 = hauntedKey(10);
        manager.initialize(k2, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity{value: 20 ether}(k2, ModifyLiquidityParams(-887_220, 887_220, 1e19, 0), "");
        CrossPoolReentrantWinner w = new CrossPoolReentrantWinner(manager, k2);

        jackpot.fund{value: 10 ether}();
        force(HauntedHook.Outcome.MiniJackpot);
        vm.expectEmit(address(hook));
        emit HauntedHook.JackpotSkipped(
            poolId, address(w), abi.encodeWithSelector(HauntedVault.TransferFailed.selector, address(w), 0.3 ether)
        );
        swap(true, -1 ether, abi.encode(address(w)));

        assertEq(jackpot.reserve(), 10 ether);
        assertEq(address(w).balance, 0);
        assertEq(hook.swapCount(), 1, "the nested swap never counted");
        assertFalse(hook.swapPending());
        // The guard is global: with a swap pending on pool 1, pool 2's beforeSwap is refused too.
        SwapParams memory p = swapParams(true, -1 ether);
        vm.startPrank(address(manager));
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(HauntedHook.SwapAlreadyPending.selector);
        hook.beforeSwap(address(this), k2, p, "");
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        vm.stopPrank();
        assertEq(hook.swapCount(), 2, "the direct callback pair counted as one swap");
        // Both pools keep working afterwards.
        force(HauntedHook.Outcome.NormalTrade);
        swapAs(address(this), k2, true, -0.01 ether, abi.encode(alice));
        swap(true, -0.01 ether, abi.encode(alice));
        assertEq(hook.swapCount(), 4);
    }

    function test_swapOnAnUninitialisedHauntedKeyReverts() public {
        PoolKey memory k3 = hauntedKey(1);
        vm.expectRevert();
        swapAs(address(this), k3, true, -0.01 ether, "");
        assertFalse(hook.haunted(k3.toId()));
        assertEq(hook.swapCount(), 0);
    }

    function test_zeroLiquidityHauntedPoolStillResolves() public {
        PoolKey memory k2 = hauntedKey(10);
        manager.initialize(k2, SQRT_PRICE_1_1);
        token.transfer(address(hook), 1_000 ether);
        force(HauntedHook.Outcome.VoidBurn);
        vm.expectEmit(address(hook));
        emit HauntedHook.BurnSkipped(k2.toId(), alice, 1_000 ether);
        BalanceDelta d = swapAs(address(this), k2, true, -1 ether, abi.encode(alice));
        assertEq(abs1(d), 0, "no VOID moved");
        assertEq(hook.swapCount(), 1);
        assertEq(hook.totalBurned(), 0);
    }
}
