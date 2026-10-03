// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HauntedFixture} from "./utils/HauntedFixture.sol";
import {HauntedGame} from "../src/HauntedGame.sol";
import {HauntedHook} from "../src/HauntedHook.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

contract RejectGameETH {
    receive() external payable {
        revert("no ETH");
    }
}

contract ReenterGameWithdrawal {
    HauntedGame private game;
    bool public rejected;

    constructor(HauntedGame g) {
        game = g;
    }

    receive() external payable {
        try game.execute(1) {}
        catch {
            rejected = true;
        }
    }
}

contract HauntedGameTest is HauntedFixture {
    HauntedGame internal game;

    function setUp() public override {
        super.setUp();
        game = hook.game();
        token.approve(address(game), type(uint256).max);
    }

    function test_plainRouterPaysBaseFeeAndCannotDraw() public {
        jackpot.fund{value: 10 ether}();
        for (uint256 i; i < 20; ++i) {
            uint256 amount = 1 ether + i;
            uint256 out = expectedOut(true, amount, 3000);
            vm.expectEmit(address(hook));
            emit HauntedHook.NormalTrade(poolId, alice, 3000);
            assertEq(abs1(swap(true, -int256(amount), abi.encode(alice))), out);
        }
        assertEq(hook.corruption(), 0);
        assertEq(jackpot.totalReleased(), 0);
        assertEq(game.ticketCount(), 0);
    }

    function test_commitLocksExactParametersAndCannotExecuteBeforeDraw() public {
        uint256 target = block.number + game.DRAW_DELAY();
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, 123);
        (address player, uint128 input, uint128 minOut, uint256 targetBlock, uint256 level, bool dir, bool resolved) =
            game.tickets(id);
        assertEq(player, address(this));
        assertEq(input, 1 ether);
        assertEq(minOut, 123);
        assertEq(targetBlock, target);
        assertEq(level, 0);
        assertTrue(dir);
        assertFalse(resolved);
        assertEq(address(game).balance, 1 ether);
        vm.expectRevert(HauntedGame.NotReady.selector);
        game.execute(id);
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.captureEntropy();
        vm.roll(target);
        game.captureEntropy();
        vm.expectRevert(HauntedGame.NotReady.selector);
        game.execute(id);
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.captureEntropy();
        vm.roll(target + 1);
        game.execute(id);
        vm.expectRevert(HauntedGame.AlreadyResolved.selector);
        game.execute(id);
        vm.expectRevert(HauntedGame.AlreadyResolved.selector);
        game.expire(id);
    }

    function test_invalidCommitAndCallbacks() public {
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.commit(true, 1 ether, 1);
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.commit{value: 1}(false, 1 ether, 1);
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.commit(true, 0, 1);
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.commit{value: 1}(true, 1, 0);
        vm.expectRevert(HauntedGame.UnauthorizedCallback.selector);
        game.unlockCallback("");
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.execute(999);
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.expire(999);
    }

    function test_freeDrawChargesZeroAndPaysOnlyCommittedPlayer() public {
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, 1);
        prepareDraw(id, HauntedHook.Outcome.FreeSwap);
        uint256 output = expectedOut(true, 1 ether, 0);
        vm.prank(bob);
        game.execute(id);
        assertEq(game.credit(address(this), address(token)), output);
        assertEq(game.credit(bob, address(token)), 0);
        assertEq(address(game).balance, 0);
        assertEq(game.lpFees0(), 0);
        game.withdraw(address(token), payable(alice));
        assertEq(token.balanceOf(alice), output);
    }

    function test_drawLevelAndFeeCannotBeChangedAfterCommit() public {
        vm.prank(owner);
        hook.forceCorruption(10);
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, 1);
        prepareDraw(id, HauntedHook.Outcome.CorruptedFee);
        (uint256 roll, uint24 fee) = game.draw(id);
        assertEq(fee, 8000);
        vm.startPrank(owner);
        hook.forceCorruption(100);
        hook.forceOutcome(HauntedHook.Outcome.FreeSwap);
        vm.stopPrank();
        vm.prevrandao(bytes32(uint256(7654321)));
        vm.roll(block.number + 1000);
        (uint256 sameRoll, uint24 sameFee) = game.draw(id);
        assertEq(sameRoll, roll);
        assertEq(sameFee, fee);
        uint256 out = expectedOut(true, 0.992 ether, 0);
        vm.expectEmit(address(hook));
        emit HauntedHook.CorruptedFee(poolId, address(this), 8000, 10);
        game.execute(id);
        assertEq(game.credit(address(this), address(token)), out);
        assertEq(hook.corruption(), 100);
    }

    function test_failedSlippageStillPaysDrawnLPFee() public {
        uint256 managerBefore = address(manager).balance;
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, type(uint128).max);
        prepareDraw(id, HauntedHook.Outcome.NormalTrade);
        game.execute(id);
        assertEq(address(manager).balance - managerBefore, 0.003 ether);
        assertEq(game.credit(address(this), address(0)), 0.997 ether);
        assertEq(game.credit(address(this), address(token)), 0);
        assertEq(hook.swapCount(), 0, "failed swap side effects roll back, fee persists");
        assertEq(hook.corruption(), 0);
        game.withdraw(address(0), payable(alice));
        assertEq(alice.balance, 0.997 ether);
        vm.expectRevert(HauntedGame.AlreadyResolved.selector);
        game.execute(id);
    }

    function test_underfundedExecutorCannotForcePaidFailure() public {
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, 1);
        prepareDraw(id, HauntedHook.Outcome.NormalTrade);
        uint256 before = address(manager).balance;
        (bool ok,) = address(game).call{gas: 400_000}(abi.encodeCall(HauntedGame.execute, (id)));
        assertFalse(ok);
        (,,,,,, bool resolved) = game.tickets(id);
        assertFalse(resolved);
        assertEq(address(manager).balance, before);
        assertEq(address(game).balance, 1 ether);
        game.execute(id);
        assertGt(game.credit(address(this), address(token)), 0);
    }

    function test_missingCaptureRefundsLessMaximumFeeWithoutReroll() public {
        uint256 before = address(manager).balance;
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, 1);
        (,,, uint256 target,,,) = game.tickets(id);
        vm.roll(target + 1);
        vm.expectRevert(HauntedGame.EntropyUnavailable.selector);
        game.execute(id);
        vm.prank(bob);
        game.expire(id);
        assertEq(game.credit(address(this), address(0)), 0.95 ether);
        assertEq(address(manager).balance - before, 0.05 ether);
        assertEq(hook.swapCount(), 0);
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.captureEntropy();
    }

    function test_capturedTicketCannotBeCancelledAndZeroEntropyIsValid() public {
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, 1);
        (,,, uint256 target,,,) = game.tickets(id);
        vm.roll(target);
        vm.prevrandao(bytes32(0));
        game.captureEntropy();
        vm.roll(target + 1);
        vm.expectRevert(HauntedGame.NotReady.selector);
        game.expire(id);
        game.execute(id);
        assertGt(game.credit(address(this), address(token)), 0);
    }

    function test_tokenInputAndFailedWithdrawalRetainsCredit() public {
        uint256 id = game.commit(false, 1 ether, 1);
        prepareDraw(id, HauntedHook.Outcome.NormalTrade);
        uint256 output = expectedOut(false, 0.997 ether, 0);
        game.execute(id);
        assertEq(game.credit(address(this), address(0)), output);
        RejectGameETH rejector = new RejectGameETH();
        vm.expectRevert(HauntedGame.TransferFailed.selector);
        game.withdraw(address(0), payable(address(rejector)));
        assertEq(game.credit(address(this), address(0)), output);
        ReenterGameWithdrawal receiver = new ReenterGameWithdrawal(game);
        game.withdraw(address(0), payable(address(receiver)));
        assertTrue(receiver.rejected());
        assertEq(game.credit(address(this), address(0)), 0);
        assertEq(address(receiver).balance, output);
    }

    function test_noLiquidityRefundsAndReservesFeeForLaterDonation() public {
        uint256 id = game.commit{value: 1 ether}(true, 1 ether, 1);
        prepareDraw(id, HauntedHook.Outcome.NormalTrade);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(FULL_RANGE_LOWER, FULL_RANGE_UPPER, -int256(uint256(LIQUIDITY)), 0), ""
        );
        vm.expectRevert(HauntedGame.InvalidInput.selector);
        game.commit{value: 1 ether}(true, 1 ether, 1);
        game.execute(id);
        assertEq(game.credit(address(this), address(0)), 0.997 ether);
        assertEq(game.lpFees0(), 0.003 ether);
        assertEq(hook.corruption(), 0);
        lpRouter.modifyLiquidity{value: 2000 ether}(
            key, ModifyLiquidityParams(FULL_RANGE_LOWER, FULL_RANGE_UPPER, int256(uint256(LIQUIDITY)), 0), ""
        );
        uint256 before = address(manager).balance;
        game.flushFees();
        assertEq(address(manager).balance - before, 0.003 ether);
        assertEq(game.lpFees0(), 0);
        assertEq(address(game).balance, 0.997 ether);
    }

    function testFuzz_failureAccountingBothCurrencies(uint128 amount, bool direction) public {
        amount = uint128(bound(amount, 1e6, 50 ether));
        uint256 id = game.commit{value: direction ? amount : 0}(direction, amount, type(uint128).max);
        prepareDraw(id, HauntedHook.Outcome.RealityCollapse);
        uint256 fee = (uint256(amount) * 50_000 + 999_999) / 1_000_000;
        uint256 before = direction ? address(manager).balance : token.balanceOf(address(manager));
        game.execute(id);
        address input = direction ? address(0) : address(token);
        assertEq(game.credit(address(this), input), amount - fee);
        uint256 afterBalance = direction ? address(manager).balance : token.balanceOf(address(manager));
        assertEq(afterBalance - before, fee);
        assertEq(hook.collapseCount(), 0, "no effect from a failed trade");
    }
}
