// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HauntedFixture} from "./utils/HauntedFixture.sol";
import {HauntedGame} from "../src/HauntedGame.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract GameHandler is Test {
    HauntedGame public immutable game;
    LaunchToken public immutable token;

    constructor(HauntedGame game_, LaunchToken token_) {
        game = game_;
        token = token_;
        token.approve(address(game), type(uint256).max);
    }

    receive() external payable {}

    function commit(uint128 amount, bool direction, bool impossibleSlippage) external {
        amount = uint128(bound(amount, 1e6, 2 ether));
        game.commit{value: direction ? amount : 0}(direction, amount, impossibleSlippage ? type(uint128).max : 1);
    }

    function settle(uint256 which, uint256 random, bool missCapture) external {
        uint256 count = game.ticketCount();
        if (count == 0) return;
        uint256 id = bound(which, 1, count);
        (,,, uint256 target,,, bool resolved) = game.tickets(id);
        if (resolved) return;
        if (block.number <= target) {
            if (!missCapture) {
                vm.roll(target);
                if (!game.captured(target)) {
                    vm.prevrandao(bytes32(random));
                    game.captureEntropy();
                }
            }
            vm.roll(target + 1);
        }
        if (game.captured(target)) game.execute(id);
        else game.expire(id);
    }

    function withdraw(bool nativeCurrency) external {
        address currency = nativeCurrency ? address(0) : address(token);
        if (game.credit(address(this), currency) != 0) game.withdraw(currency, payable(address(this)));
    }
}

contract HauntedGameInvariantTest is HauntedFixture {
    GameHandler internal handler;
    HauntedGame internal game;

    function setUp() public override {
        super.setUp();
        game = hook.game();
        handler = new GameHandler(game, token);
        vm.deal(address(handler), 1_000_000 ether);
        token.transfer(address(handler), 1_000_000 ether);
        targetContract(address(handler));
    }

    function invariant_escrowAndCreditsConserveBothCurrencies() public view {
        uint256 ethLiability = game.lpFees0() + game.credit(address(handler), address(0));
        uint256 tokenLiability = game.lpFees1() + game.credit(address(handler), address(token));
        for (uint256 id = 1; id <= game.ticketCount(); ++id) {
            (, uint128 amount,,,, bool direction, bool resolved) = game.tickets(id);
            if (!resolved) {
                if (direction) ethLiability += amount;
                else tokenLiability += amount;
            }
        }
        assertEq(address(game).balance, ethLiability);
        assertEq(token.balanceOf(address(game)), tokenLiability);
        assertFalse(game.executing());
        assertFalse(hook.swapPending());
        assertLe(hook.corruption(), 100);
    }
}
