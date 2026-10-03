// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HauntedFixture} from "./utils/HauntedFixture.sol";
import {HauntedGame} from "../src/HauntedGame.sol";
import {HauntedHook} from "../src/HauntedHook.sol";
import {HauntedVault} from "../src/HauntedVault.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";

/// @dev A jackpot winner of an ordinary router swap that tries to settle somebody else's captured
/// ticket from inside the payout, where the PoolManager is unlocked by the router. It records the
/// refusal and then accepts the ETH so the payout itself succeeds.
contract SettleDuringPayout {
    HauntedGame private game;
    uint256 private ticket;
    bytes public executeReason;
    bytes public expireReason;
    bytes public flushReason;

    constructor(HauntedGame g, uint256 id) {
        game = g;
        ticket = id;
    }

    receive() external payable {
        (bool ok, bytes memory reason) = address(game).call(abi.encodeCall(HauntedGame.execute, (ticket)));
        require(!ok, "execute must be refused inside an unlock");
        executeReason = reason;
        (ok, reason) = address(game).call(abi.encodeCall(HauntedGame.expire, (ticket)));
        require(!ok, "expire must be refused inside an unlock");
        expireReason = reason;
        (ok, reason) = address(game).call(abi.encodeCall(HauntedGame.flushFees, ()));
        require(!ok, "flushFees must be refused inside an unlock");
        flushReason = reason;
    }
}

/// @dev A player that refuses every ETH transfer. Its jackpot must fail without failing its trade.
contract RefusingPlayer {
    receive() external payable {
        revert("refused");
    }
}

/// @dev A player whose receive re-enters the game. The re-entry is refused, which fails the payout.
contract ReenteringPlayer {
    HauntedGame private game;

    constructor(HauntedGame g) {
        game = g;
    }

    receive() external payable {
        game.withdraw(address(0), payable(address(this)));
    }
}

/// @notice Inputs HauntedGame did not obviously consider: settlement attempted from inside a router
/// swap's payout, hostile contract players, one-wei tickets, partial fills, shared target blocks,
/// the int128 boundary, withdraw destinations, the execution gas boundary and a draw whose level
/// outlives a reality collapse. Every outcome is also settled through the escrow path with a fee oracle.
contract HauntedGameEdgeTest is HauntedFixture {
    using StateLibrary for IPoolManager;

    HauntedGame internal game;

    function setUp() public override {
        super.setUp();
        game = hook.game();
        token.approve(address(game), type(uint256).max);
    }

    function ceilFee(uint256 amount, uint24 fee) internal pure returns (uint256) {
        return (amount * fee + 999_999) / 1_000_000;
    }

    // ------------------------------------------------------------------ unlock guard via a hook payout

    /// @dev The F11 guard must hold on the route the fix did not test: a payout recipient inside an
    /// ordinary swap, where the router (not an outsider's callback) holds the manager unlock.
    function test_jackpotWinnerCannotSettleATicketFromInsideAnOrdinarySwap() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, 1);
        prepareDraw(id, HauntedHook.Outcome.MiniJackpot);

        SettleDuringPayout winner = new SettleDuringPayout(game, id);
        jackpot.fund{value: 10 ether}();
        vm.prank(owner);
        hook.forceOutcome(HauntedHook.Outcome.MiniJackpot);
        uint256 managerBefore = address(manager).balance;

        vm.expectEmit(address(hook));
        emit HauntedHook.MiniJackpot(poolId, address(winner), 0.3 ether);
        swap(true, -1 ether, abi.encode(address(winner)));

        assertEq(address(winner).balance, 0.3 ether, "the payout itself succeeded");
        assertEq(winner.executeReason(), abi.encodeWithSelector(HauntedGame.ManagerUnlocked.selector));
        assertEq(winner.expireReason(), abi.encodeWithSelector(HauntedGame.ManagerUnlocked.selector));
        assertEq(winner.flushReason(), abi.encodeWithSelector(HauntedGame.ManagerUnlocked.selector));
        (,,,,,, bool resolved) = game.tickets(id);
        assertFalse(resolved, "alice's ticket stays open");
        assertEq(address(game).balance, 1 ether, "escrow untouched");
        assertEq(game.lpFees0(), 0, "no fee charged");
        assertEq(address(manager).balance, managerBefore + 1 ether, "only the router swap's ETH moved");

        // Once the cooldown passes, a top-level settlement pays alice her own drawn jackpot.
        vm.prank(owner);
        hook.clearForcedOutcome();
        vm.warp(block.timestamp + JACKPOT_COOLDOWN);
        vm.prank(bob);
        game.execute(id);
        assertEq(alice.balance, 9.7 ether * 300 / 10_000, "3% of the remaining reserve");
        assertGt(game.credit(alice, address(token)), 0);
        assertEq(address(game).balance, 0);
    }

    // ------------------------------------------------------------------ hostile contract players

    function test_playerRefusingEthKeepsItsSwapOutputAndForfeitsOnlyTheJackpot() public {
        RefusingPlayer player = new RefusingPlayer();
        vm.deal(address(player), 1 ether);
        vm.prank(address(player));
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, 1);
        prepareDraw(id, HauntedHook.Outcome.MiniJackpot);
        jackpot.fund{value: 10 ether}();
        uint256 out = expectedOut(true, 0.997 ether, 0);

        vm.expectEmit(address(hook));
        emit HauntedHook.JackpotSkipped(
            poolId,
            address(player),
            abi.encodeWithSelector(HauntedVault.TransferFailed.selector, address(player), 0.3 ether)
        );
        vm.prank(bob);
        game.execute(id);

        assertEq(game.credit(address(player), address(token)), out, "the trade itself settled");
        assertEq(game.credit(address(player), address(0)), 0);
        assertEq(jackpot.reserve(), 10 ether, "nothing left the vault");
        assertEq(jackpot.releaseCount(), 0, "a failed payout consumes no cooldown");
        assertEq(hook.corruption(), 1, "the outcome still corrupts");
        assertEq(address(game).balance, 0);
        assertEq(token.balanceOf(address(game)), out);
        vm.prank(address(player));
        game.withdraw(address(token), payable(alice));
        assertEq(token.balanceOf(alice), out);
    }

    function test_playerReenteringDuringItsOwnPayoutForfeitsOnlyTheJackpot() public {
        ReenteringPlayer player = new ReenteringPlayer(game);
        vm.deal(address(player), 1 ether);
        vm.prank(address(player));
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, 1);
        prepareDraw(id, HauntedHook.Outcome.MiniJackpot);
        jackpot.fund{value: 10 ether}();
        uint256 out = expectedOut(true, 0.997 ether, 0);

        vm.expectEmit(address(hook));
        emit HauntedHook.JackpotSkipped(
            poolId,
            address(player),
            abi.encodeWithSelector(HauntedVault.TransferFailed.selector, address(player), 0.3 ether)
        );
        game.execute(id);
        assertEq(game.credit(address(player), address(token)), out);
        assertEq(address(player).balance, 0, "the re-entrant payout never landed");
        assertEq(jackpot.totalReleased(), 0);
        assertFalse(game.executing());
        assertFalse(hook.swapPending());
    }

    // ------------------------------------------------------------------ extremes of the input amount

    function test_oneWeiTicketIsEntirelyFeeAndNeverReachesTheHook() public {
        uint256 managerBefore = address(manager).balance;
        uint256 id = game.commit{value: 1}(true, 1, 1);
        prepareDraw(id, HauntedHook.Outcome.NormalTrade);
        // ceil(1 * 3000 / 1e6) is one wei: nothing is left to swap, so the manager refuses the zero swap.
        vm.expectEmit(address(game));
        emit HauntedGame.TradeFailed(id, abi.encodeWithSelector(IPoolManager.SwapAmountCannotBeZero.selector));
        game.execute(id);
        assertEq(address(manager).balance, managerBefore + 1, "the wei was donated to LPs");
        assertEq(game.credit(address(this), address(0)), 0);
        assertEq(game.credit(address(this), address(token)), 0);
        assertEq(address(game).balance, 0);
        assertEq(hook.swapCount(), 0, "the hook never saw the swap");
        assertEq(hook.corruption(), 0);
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.withdraw(address(0), payable(alice));
    }

    function test_amountBoundaryAtInt128Max() public {
        uint128 limit = uint128(type(int128).max);
        // One above the limit is refused before any transfer is attempted, in both directions.
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.commit(false, limit + 1, 1);
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.commit{value: 1}(true, limit + 1, 1);
        // Exactly the limit passes the amount check and fails only on funds this contract lacks.
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), token.balanceOf(address(this)), limit
            )
        );
        game.commit(false, limit, 1);
        assertEq(game.ticketCount(), 0);
    }

    /// forge-config: default.fuzz.runs = 512
    /// @dev Every drawn outcome settles through escrow with the ceiling of the drawn fee donated to
    /// LPs, zero additional hook fee on the swap, and the whole input accounted for in the manager.
    function testFuzz_everyOutcomeSettlesWithCeilingFeeAndNoHookFee(uint8 outcomeRaw, uint256 amount, bool z4o) public {
        HauntedHook.Outcome o = HauntedHook.Outcome(bound(outcomeRaw, 0, 7));
        amount = bound(amount, 1e6, 20 ether);
        uint256 id = game.commit{value: z4o ? amount : 0}(z4o, uint128(amount), 1);
        prepareDraw(id, o);
        (, uint24 fee) = game.draw(id);
        assertEq(fee, hook.feeForOutcome(o, 0), "drawn fee is the outcome's fee at the commit level");
        uint256 feeAmount = ceilFee(amount, fee);
        uint256 out = expectedOut(z4o, amount - feeAmount, 0);
        uint256 managerEth = address(manager).balance;
        uint256 managerTok = token.balanceOf(address(manager));

        vm.prank(bob);
        game.execute(id);

        address outCurrency = z4o ? address(token) : address(0);
        assertEq(game.credit(address(this), outCurrency), out, "output at zero swap fee");
        assertEq(game.credit(address(this), z4o ? address(0) : address(token)), 0, "no refund on success");
        if (z4o) {
            assertEq(address(manager).balance - managerEth, amount, "fee donated plus net swapped");
            assertEq(managerTok - token.balanceOf(address(manager)), out);
        } else {
            assertEq(token.balanceOf(address(manager)) - managerTok, amount);
            assertEq(managerEth - address(manager).balance, out);
        }
        assertEq(game.lpFees0() + game.lpFees1(), 0, "nothing left reserved while the pool has liquidity");
        assertEq(hook.swapCount(), 1);
        uint256 expectedCorruption =
            o == HauntedHook.Outcome.RealityCollapse ? 0 : o == HauntedHook.Outcome.CorruptedFee ? 5 : 1;
        assertEq(hook.corruption(), expectedCorruption);
        assertEq(hook.collapseCount(), o == HauntedHook.Outcome.RealityCollapse ? 1 : 0);
        assertEq(lpFee(), 3000, "the stored pool fee is never rewritten");
    }

    // ------------------------------------------------------------------ partial fills

    function test_partialFillOnConcentratedLiquidityFailsAndStillPaysTheFee() public {
        // Replace the full-range liquidity with a narrow band around the current tick.
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(FULL_RANGE_LOWER, FULL_RANGE_UPPER, -int256(uint256(LIQUIDITY)), 0), ""
        );
        lpRouter.modifyLiquidity{value: 10 ether}(
            key, ModifyLiquidityParams(-60, 60, int256(uint256(LIQUIDITY)), 0), ""
        );
        assertEq(manager.getLiquidity(poolId), LIQUIDITY);

        uint256 id = game.commit{value: 50 ether}(true, 50 ether, 1);
        prepareDraw(id, HauntedHook.Outcome.NormalTrade);
        uint256 managerBefore = address(manager).balance;
        vm.expectEmit(address(game));
        emit HauntedGame.TradeFailed(id, abi.encodeWithSelector(HauntedGame.SlippageOrPartialFill.selector));
        game.execute(id);

        assertEq(address(manager).balance - managerBefore, 0.15 ether, "the 0.30% fee was donated");
        assertEq(game.credit(address(this), address(0)), 49.85 ether, "the net input is refundable");
        assertEq(game.credit(address(this), address(token)), 0);
        assertEq(hook.swapCount(), 0, "the partially filled swap rolled back");
        assertEq(hook.corruption(), 0);
        assertEq(manager.getLiquidity(poolId), LIQUIDITY, "the band is still active at the unchanged price");
    }

    // ------------------------------------------------------------------ shared target blocks

    function test_ticketsSharingATargetBlockShareOneCaptureAndSettleIndependently() public {
        vm.deal(alice, 2 ether);
        uint256 first = game.commit{value: 1 ether}(true, 1 ether, 1);
        vm.prank(alice);
        uint256 second = game.commit{value: 2 ether}(true, 2 ether, 1);
        (,,, uint256 target,,,) = game.tickets(first);
        (,,, uint256 target2,,,) = game.tickets(second);
        assertEq(target, target2);

        vm.roll(target);
        vm.prevrandao(bytes32(uint256(31337)));
        vm.prank(bob);
        game.captureEntropy();
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.captureEntropy();
        vm.roll(target + 1);
        (uint256 rollA,) = game.draw(first);
        (uint256 rollB,) = game.draw(second);
        assertLt(rollA, 1000);
        assertLt(rollB, 1000);

        game.execute(second);
        vm.expectRevert(HauntedGame.NotReady.selector);
        game.expire(first);
        game.execute(first);
        assertEq(address(game).balance, 0, "both escrows left");
        assertGt(game.credit(address(this), address(token)) + game.credit(address(this), address(0)), 0);
        assertGt(game.credit(alice, address(token)) + game.credit(alice, address(0)), 0);
        assertEq(game.credit(bob, address(token)), 0, "the capturer earns nothing");
    }

    function test_expireAndExecuteBothWaitAtTheTargetBlock() public {
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, 1);
        (,,, uint256 target,,,) = game.tickets(id);
        vm.roll(target);
        vm.expectRevert(HauntedGame.NotReady.selector);
        game.expire(id);
        vm.expectRevert(HauntedGame.NotReady.selector);
        game.execute(id);
        assertEq(address(game).balance, 1 ether);
        vm.roll(target + 1);
        vm.expectRevert(HauntedGame.EntropyUnavailable.selector);
        game.execute(id);
        game.expire(id);
        vm.expectRevert(HauntedGame.AlreadyResolved.selector);
        game.expire(id);
    }

    // ------------------------------------------------------------------ withdrawals

    function test_withdrawRefusesUnknownCurrencyTheGameAndNonPayableDestinations() public {
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, type(uint128).max);
        prepareDraw(id, HauntedHook.Outcome.FreeSwap);
        game.execute(id);
        assertEq(game.credit(address(this), address(0)), 1 ether, "free draw, failed trade: full refund");

        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.withdraw(address(1), payable(alice));
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.withdraw(address(0), payable(address(game)));
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.withdraw(address(0), payable(address(0)));
        vm.expectRevert(HauntedGame.TransferFailed.selector);
        game.withdraw(address(0), payable(address(manager)));
        vm.prank(alice);
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.withdraw(address(0), payable(alice));
        assertEq(game.credit(address(this), address(0)), 1 ether, "every refusal left the credit intact");

        game.withdraw(address(0), payable(alice));
        assertEq(alice.balance, 1 ether);
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.withdraw(address(0), payable(alice));
        assertEq(address(game).balance, 0);
    }

    // ------------------------------------------------------------------ execution gas boundary

    function test_executionGasBoundaryIsAtomic() public {
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, 1);
        prepareDraw(id, HauntedHook.Outcome.NormalTrade);
        uint256 managerBefore = address(manager).balance;
        // Enough to charge the fee and flush it, not enough for the fixed swap budget plus margin.
        (bool ok, bytes memory reason) = address(game).call{gas: 2_250_000}(abi.encodeCall(HauntedGame.execute, (id)));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(HauntedGame.InsufficientExecutionGas.selector));
        (,,,,,, bool resolved) = game.tickets(id);
        assertFalse(resolved, "the whole settlement rolled back");
        assertEq(game.lpFees0(), 0);
        assertEq(address(manager).balance, managerBefore, "the flushed fee rolled back too");
        assertEq(address(game).balance, 1 ether);

        (ok,) = address(game).call{gas: 3_000_000}(abi.encodeCall(HauntedGame.execute, (id)));
        assertTrue(ok, "the documented budget plus margin suffices");
        assertEq(address(manager).balance - managerBefore, 1 ether);
        assertGt(game.credit(address(this), address(token)), 0);
    }

    function test_flushFeesWithNothingReservedIsANoOp() public {
        uint256 managerBefore = address(manager).balance;
        vm.prank(alice);
        game.flushFees();
        assertEq(address(manager).balance, managerBefore);
        assertEq(game.lpFees0() + game.lpFees1(), 0);
    }

    // ------------------------------------------------------------------ token input with a payout

    function test_tokenTicketJackpotPaysThePlayerAndCreditsEth() public {
        token.transfer(alice, 1 ether);
        vm.startPrank(alice);
        token.approve(address(game), 1 ether);
        uint256 id = game.commit(false, 1 ether, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(address(game)), 1 ether);
        prepareDraw(id, HauntedHook.Outcome.MiniJackpot);
        jackpot.fund{value: 100 ether}();
        uint256 out = expectedOut(false, 0.997 ether, 0);
        uint256 managerTok = token.balanceOf(address(manager));

        vm.expectEmit(address(hook));
        emit HauntedHook.MiniJackpot(poolId, alice, 3 ether);
        vm.prank(bob);
        game.execute(id);

        assertEq(alice.balance, 3 ether, "the jackpot goes straight to the committed player");
        assertEq(game.credit(alice, address(0)), out, "ETH output is credited, not pushed");
        assertEq(game.credit(alice, address(token)), 0);
        assertEq(token.balanceOf(address(manager)) - managerTok, 1 ether, "fee donated plus net swapped");
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(address(game).balance, out);
        vm.prank(alice);
        game.withdraw(address(0), payable(alice));
        assertEq(alice.balance, 3 ether + out);
    }

    // ------------------------------------------------------------------ commit-time level survives a collapse

    function test_commitLevelSurvivesACollapseBeforeTheDraw() public {
        vm.prank(owner);
        hook.forceCorruption(40);
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, 1);
        // A forced collapse on an ordinary swap resets the live corruption before the draw.
        vm.startPrank(owner);
        hook.forceOutcome(HauntedHook.Outcome.RealityCollapse);
        vm.stopPrank();
        swap(true, -0.1 ether, abi.encode(alice));
        assertEq(hook.corruption(), 0);
        vm.prank(owner);
        hook.clearForcedOutcome();

        prepareDraw(id, HauntedHook.Outcome.CorruptedFee);
        (, uint24 fee) = game.draw(id);
        assertEq(fee, 3000 + 40 * 500, "priced at the committed level, not the live one");
        uint256 managerBefore = address(manager).balance;
        uint256 out = expectedOut(true, 1 ether - 0.023 ether, 0);
        vm.expectEmit(address(hook));
        emit HauntedHook.CorruptedFee(poolId, address(this), 23_000, 40);
        game.execute(id);
        assertEq(address(manager).balance - managerBefore, 1 ether);
        assertEq(game.credit(address(this), address(token)), out);
        assertEq(hook.corruption(), 5, "the live level only gains the corrupted-fee increment");
    }
}
