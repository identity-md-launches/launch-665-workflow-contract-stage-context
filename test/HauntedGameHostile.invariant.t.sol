// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HauntedFixture} from "./utils/HauntedFixture.sol";
import {HauntedGame} from "../src/HauntedGame.sol";
import {HauntedHook} from "../src/HauntedHook.sol";
import {JackpotVault} from "../src/JackpotVault.sol";
import {CharityVault} from "../src/CharityVault.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

/// @dev A player that refuses all ETH: its jackpots must fail while its trades and refunds stand.
contract RefusingActor {
    receive() external payable {
        revert("refused");
    }
}

/// @dev A player that, on every ETH receipt, tries to settle a ticket, flush fees and recycle the
/// received ETH into a fresh commitment, swallowing refusals so the payout itself lands. Settlement
/// and flushing must never succeed from inside a payout (the manager is unlocked); a commit can only
/// succeed during an ordinary swap, when the game is not mid-call.
contract ReenteringActor {
    HauntedGame private game;
    uint256 public settlementsAccepted;
    uint256 public commitsFromPayout;

    constructor(HauntedGame g) {
        game = g;
    }

    receive() external payable {
        (bool ok,) = address(game).call(abi.encodeCall(HauntedGame.execute, (1)));
        if (ok) ++settlementsAccepted;
        (ok,) = address(game).call(abi.encodeCall(HauntedGame.flushFees, ()));
        if (ok) ++settlementsAccepted;
        if (msg.value != 0 && msg.value <= type(uint128).max) {
            (ok,) =
                address(game).call{value: msg.value}(abi.encodeCall(HauntedGame.commit, (true, uint128(msg.value), 1)));
            if (ok) ++commitsFromPayout;
        }
    }
}

/// @dev Opens its own PoolManager unlock and calls a game entry point from inside it.
contract ForeignUnlock is IUnlockCallback {
    IPoolManager private manager;
    HauntedGame private game;
    bool public lastOk;
    bytes public lastReason;

    constructor(IPoolManager m, HauntedGame g) {
        manager = m;
        game = g;
    }

    function run(bytes calldata inner) external {
        manager.unlock(inner);
    }

    function unlockCallback(bytes calldata inner) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (lastOk, lastReason) = address(game).call(inner);
        return "";
    }
}

/// @notice Drives the game with five players (three EOAs, a refuser and a re-enterer), funded vaults,
/// forced ordinary swaps, liquidity that comes and goes, foreign unlocks and time. Every settlement is
/// checked against the contract's own quote and against where the money must have gone.
contract HostileGameHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint128 internal constant BAND_LIQUIDITY = 1e21;
    int24 internal constant LOWER = -887_220;
    int24 internal constant UPPER = 887_220;
    bytes32 internal constant HANDLER_SALT = bytes32(uint256(1));

    HauntedGame public game;
    HauntedHook public hook;
    LaunchToken public token;
    IPoolManager public manager;
    JackpotVault public jackpot;
    CharityVault public charity;
    PoolSwapTest public router;
    PoolModifyLiquidityTest public lpRouter;
    PoolKey internal key;
    PoolId internal poolId;
    address public owner;

    address[] public actors;
    RefusingActor public refuser;
    ReenteringActor public reenterer;
    ForeignUnlock public outsider;

    uint256 public jackpotFunded;
    uint256 public charityFunded;
    bool public liquidityPresent;

    /// @dev 0 open, 1 executed, 2 expired.
    mapping(uint256 => uint8) public resolution;
    uint256 public executedCount;
    uint256 public expiredCount;
    uint256 public failedTrades;
    uint256 public successfulTrades;
    uint256 public jackpotsPaid;

    bool public oracleViolated;
    bool public feeCapViolated;
    bool public accountingViolated;
    bool public reservedWithLiquidity;
    bool public foreignUnlockViolated;
    bool public jackpotCapViolated;
    bool public cooldownViolated;

    constructor(
        HauntedGame g,
        HauntedHook h,
        LaunchToken t,
        IPoolManager m,
        JackpotVault j,
        CharityVault c,
        PoolSwapTest r,
        PoolModifyLiquidityTest lr,
        PoolKey memory k,
        address owner_
    ) {
        game = g;
        hook = h;
        token = t;
        manager = m;
        jackpot = j;
        charity = c;
        router = r;
        lpRouter = lr;
        key = k;
        poolId = k.toId();
        owner = owner_;
        refuser = new RefusingActor();
        reenterer = new ReenteringActor(g);
        outsider = new ForeignUnlock(m, g);
        for (uint256 i; i < 3; ++i) {
            actors.push(makeAddr(string.concat("player", vm.toString(i))));
        }
        actors.push(address(refuser));
        actors.push(address(reenterer));
    }

    receive() external payable {}

    /// @dev Called once by the test after it has funded this contract with VOID.
    function init() external {
        token.approve(address(router), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        for (uint256 i; i < actors.length; ++i) {
            token.transfer(actors[i], 1_000 ether);
            vm.prank(actors[i]);
            token.approve(address(game), type(uint256).max);
        }
        _addLiquidity();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function ceilFee(uint256 amount, uint24 fee) internal pure returns (uint256) {
        return (amount * fee + 999_999) / 1_000_000;
    }

    function selectorOf(bytes memory reason) internal pure returns (bytes4 sel) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            sel := mload(add(reason, 32))
        }
    }

    // ------------------------------------------------------------------ liquidity, funding, time

    function _addLiquidity() private {
        vm.deal(address(this), address(this).balance + 5_000 ether);
        lpRouter.modifyLiquidity{value: 5_000 ether}(
            key, ModifyLiquidityParams(LOWER, UPPER, int256(uint256(BAND_LIQUIDITY)), HANDLER_SALT), ""
        );
        liquidityPresent = true;
    }

    function toggleLiquidity() external {
        if (liquidityPresent) {
            lpRouter.modifyLiquidity(
                key, ModifyLiquidityParams(LOWER, UPPER, -int256(uint256(BAND_LIQUIDITY)), HANDLER_SALT), ""
            );
            liquidityPresent = false;
        } else {
            _addLiquidity();
        }
        if ((manager.getLiquidity(poolId) != 0) != liquidityPresent) accountingViolated = true;
    }

    function fundJackpot(uint256 amount) external {
        amount = bound(amount, 0, 200 ether);
        vm.deal(address(this), address(this).balance + amount);
        jackpot.fund{value: amount}();
        jackpotFunded += amount;
    }

    function fundCharity(uint256 amount) external {
        amount = bound(amount, 0, 200 ether);
        vm.deal(address(this), address(this).balance + amount);
        charity.fund{value: amount}();
        charityFunded += amount;
    }

    function warp(uint256 by) external {
        by = bound(by, 0, 1 days);
        vm.warp(block.timestamp + by);
    }

    function rollForward(uint256 by) external {
        by = bound(by, 1, 300);
        vm.roll(block.number + by);
    }

    // ------------------------------------------------------------------ the game

    struct CommitExpectation {
        address actor;
        uint128 amount;
        bool direction;
        uint256 countBefore;
        uint256 balanceBefore;
        uint256 tokenBefore;
    }

    function commit(uint256 actorSeed, uint128 amount, bool direction, uint8 slippage) external {
        CommitExpectation memory e = CommitExpectation({
            actor: actors[actorSeed % actors.length],
            amount: uint128(bound(amount, 1, 3 ether)),
            direction: direction,
            countBefore: game.ticketCount(),
            balanceBefore: address(game).balance,
            tokenBefore: token.balanceOf(address(game))
        });
        uint128 minOut = slippage % 3 == 0 ? type(uint128).max : 1;
        if (direction) vm.deal(e.actor, e.actor.balance + e.amount);
        bool predicted = manager.getLiquidity(poolId) != 0;

        vm.prank(e.actor);
        (bool ok, bytes memory ret) = address(game).call{value: direction ? e.amount : 0}(
            abi.encodeCall(HauntedGame.commit, (direction, e.amount, minOut))
        );
        if (ok != predicted) oracleViolated = true;
        if (!ok) {
            if (selectorOf(ret) != HauntedGame.InvalidInput.selector) oracleViolated = true;
            if (game.ticketCount() != e.countBefore) accountingViolated = true;
            return;
        }
        _checkCommitted(abi.decode(ret, (uint256)), e);
    }

    function _checkCommitted(uint256 id, CommitExpectation memory e) private {
        if (id != e.countBefore + 1) accountingViolated = true;
        (address player, uint128 stored,, uint256 target, uint256 level, bool dir, bool resolved) = game.tickets(id);
        if (player != e.actor || stored != e.amount || dir != e.direction || resolved) accountingViolated = true;
        if (target != block.number + game.DRAW_DELAY() || level != hook.corruption()) accountingViolated = true;
        if (!game.requested(target)) accountingViolated = true;
        if (e.direction && address(game).balance != e.balanceBefore + e.amount) accountingViolated = true;
        if (!e.direction && token.balanceOf(address(game)) != e.tokenBefore + e.amount) accountingViolated = true;
    }

    /// @dev Moves to the chosen open ticket's target block when it is still ahead.
    function advanceToTarget(uint256 ticketSeed) external {
        uint256 count = game.ticketCount();
        if (count == 0) return;
        uint256 id = bound(ticketSeed, 1, count);
        (,,, uint256 target,,, bool resolved) = game.tickets(id);
        if (resolved || block.number >= target) return;
        vm.roll(target);
    }

    function captureNow(uint256 entropy) external {
        uint256 bn = block.number;
        bool predicted = game.requested(bn) && !game.captured(bn);
        vm.prevrandao(bytes32(entropy));
        (bool ok, bytes memory reason) = address(game).call(abi.encodeCall(HauntedGame.captureEntropy, ()));
        if (ok != predicted) oracleViolated = true;
        if (!ok) {
            if (selectorOf(reason) != HauntedGame.InvalidInput.selector) oracleViolated = true;
            return;
        }
        if (!game.captured(bn) || game.entropy(bn) != bytes32(entropy)) accountingViolated = true;
    }

    struct Snapshot {
        address player;
        uint128 amountIn;
        bool dir;
        uint256 reserved0;
        uint256 reserved1;
        uint256 managerEth;
        uint256 managerTok;
        uint256 creditIn;
        uint256 creditOut;
        uint256 jackpotReleases;
        uint256 jackpotReserve;
        uint256 jackpotAvailableAt;
        bool liquid;
    }

    function _snapshot(uint256 id) private view returns (Snapshot memory s) {
        (s.player, s.amountIn,,,, s.dir,) = game.tickets(id);
        s.reserved0 = game.lpFees0();
        s.reserved1 = game.lpFees1();
        s.managerEth = address(manager).balance;
        s.managerTok = token.balanceOf(address(manager));
        address inCurrency = s.dir ? address(0) : address(token);
        address outCurrency = s.dir ? address(token) : address(0);
        s.creditIn = game.credit(s.player, inCurrency);
        s.creditOut = game.credit(s.player, outCurrency);
        s.jackpotReleases = jackpot.releaseCount();
        s.jackpotReserve = jackpot.reserve();
        s.jackpotAvailableAt = jackpot.releaseAvailableAt();
        s.liquid = manager.getLiquidity(poolId) != 0;
    }

    /// @dev Where the money must be after a settlement that charged `feeAmount` and either traded
    /// (`traded`, output credited) or refunded the net input. Fees are donated iff the pool had
    /// liquidity; previously reserved fees are flushed with them.
    function _checkSettlement(Snapshot memory s, uint256 feeAmount, bool traded) private {
        uint256 net = s.amountIn - feeAmount;
        uint256 outDelta = _checkCredits(s, net, traded);
        _checkReserved(s, feeAmount, traded);
        _checkManagerBalances(s, feeAmount, net, traded, outDelta);
        _checkJackpot(s);
    }

    function _checkCredits(Snapshot memory s, uint256 net, bool traded) private returns (uint256 outDelta) {
        uint256 inDelta = game.credit(s.player, s.dir ? address(0) : address(token)) - s.creditIn;
        outDelta = game.credit(s.player, s.dir ? address(token) : address(0)) - s.creditOut;
        if (traded) {
            if (outDelta == 0 || inDelta != 0) accountingViolated = true;
            ++successfulTrades;
        } else {
            if (outDelta != 0 || inDelta != net) accountingViolated = true;
            ++failedTrades;
        }
    }

    function _checkReserved(Snapshot memory s, uint256 feeAmount, bool traded) private {
        if (s.liquid) {
            if (game.lpFees0() != 0 || game.lpFees1() != 0) reservedWithLiquidity = true;
            return;
        }
        if (traded) accountingViolated = true;
        uint256 expected0 = s.reserved0 + (s.dir ? feeAmount : 0);
        uint256 expected1 = s.reserved1 + (s.dir ? 0 : feeAmount);
        if (game.lpFees0() != expected0 || game.lpFees1() != expected1) accountingViolated = true;
    }

    /// @dev Fees (this one and any previously reserved) reach the manager iff the pool had liquidity;
    /// a traded net input reaches it too, and the traded output leaves it towards the game.
    function _checkManagerBalances(Snapshot memory s, uint256 feeAmount, uint256 net, bool traded, uint256 outDelta)
        private
    {
        uint256 expectedEth = s.managerEth;
        uint256 expectedTok = s.managerTok;
        if (s.liquid) {
            expectedEth += s.reserved0 + (s.dir ? feeAmount : 0);
            expectedTok += s.reserved1 + (s.dir ? 0 : feeAmount);
        }
        if (traded) {
            if (s.dir) {
                expectedEth += net;
                expectedTok -= outDelta;
            } else {
                expectedTok += net;
                expectedEth -= outDelta;
            }
        }
        if (address(manager).balance != expectedEth || token.balanceOf(address(manager)) != expectedTok) {
            accountingViolated = true;
        }
    }

    function _checkJackpot(Snapshot memory s) private {
        if (jackpot.releaseCount() <= s.jackpotReleases) return;
        ++jackpotsPaid;
        uint256 paid = s.jackpotReserve - jackpot.reserve();
        if (paid > s.jackpotReserve * 300 / 10_000) jackpotCapViolated = true;
        if (block.timestamp < s.jackpotAvailableAt) cooldownViolated = true;
        if (s.player.balance == 0 || s.player == address(refuser)) accountingViolated = true;
    }

    function execute(uint256 ticketSeed) external {
        uint256 count = game.ticketCount();
        uint256 id = bound(ticketSeed, 1, count + 1);
        bool exists = id <= count;
        bytes4 expected;
        bool predicted;
        Snapshot memory s;
        uint24 fee;
        if (!exists) {
            expected = HauntedGame.InvalidInput.selector;
        } else {
            (,,, uint256 target,,, bool resolved) = game.tickets(id);
            if (resolved) {
                expected = HauntedGame.AlreadyResolved.selector;
            } else if (block.number <= target) {
                expected = HauntedGame.NotReady.selector;
            } else if (!game.captured(target)) {
                expected = HauntedGame.EntropyUnavailable.selector;
            } else {
                predicted = true;
                s = _snapshot(id);
                (, fee) = game.draw(id);
            }
        }
        (bool ok, bytes memory reason) = address(game).call(abi.encodeCall(HauntedGame.execute, (id)));
        if (ok != predicted) oracleViolated = true;
        if (!ok) {
            if (selectorOf(reason) != expected) oracleViolated = true;
            return;
        }
        (,,,,,, bool nowResolved) = game.tickets(id);
        if (!nowResolved || resolution[id] != 0) accountingViolated = true;
        resolution[id] = 1;
        ++executedCount;
        uint256 feeAmount = ceilFee(s.amountIn, fee);
        if (fee > game.MAX_FEE() || feeAmount > ceilFee(s.amountIn, game.MAX_FEE())) feeCapViolated = true;
        address outCurrency = s.dir ? address(token) : address(0);
        bool traded = game.credit(s.player, outCurrency) > s.creditOut;
        _checkSettlement(s, feeAmount, traded);
        if (game.executing() || hook.swapPending()) accountingViolated = true;
    }

    function expire(uint256 ticketSeed) external {
        uint256 count = game.ticketCount();
        uint256 id = bound(ticketSeed, 1, count + 1);
        bool exists = id <= count;
        bytes4 expected;
        bool predicted;
        Snapshot memory s;
        if (!exists) {
            expected = HauntedGame.InvalidInput.selector;
        } else {
            (,,, uint256 target,,, bool resolved) = game.tickets(id);
            if (resolved) {
                expected = HauntedGame.AlreadyResolved.selector;
            } else if (block.number <= target || game.captured(target)) {
                expected = HauntedGame.NotReady.selector;
            } else {
                predicted = true;
                s = _snapshot(id);
            }
        }
        (bool ok, bytes memory reason) = address(game).call(abi.encodeCall(HauntedGame.expire, (id)));
        if (ok != predicted) oracleViolated = true;
        if (!ok) {
            if (selectorOf(reason) != expected) oracleViolated = true;
            return;
        }
        (,,,,,, bool nowResolved) = game.tickets(id);
        if (!nowResolved || resolution[id] != 0) accountingViolated = true;
        resolution[id] = 2;
        ++expiredCount;
        _checkSettlement(s, ceilFee(s.amountIn, game.MAX_FEE()), false);
        if (jackpot.releaseCount() != s.jackpotReleases) accountingViolated = true;
    }

    function withdraw(uint256 actorSeed, bool nativeCurrency, uint256 destSeed) external {
        address actor = actors[actorSeed % actors.length];
        address currency = nativeCurrency ? address(0) : address(token);
        address payable to = payable(actors[destSeed % actors.length]);
        uint256 amount = game.credit(actor, currency);
        bool predicted = amount != 0 && !(nativeCurrency && to == address(refuser));
        uint256 toBefore = nativeCurrency ? to.balance : token.balanceOf(to);

        vm.prank(actor);
        (bool ok, bytes memory reason) = address(game).call(abi.encodeCall(HauntedGame.withdraw, (currency, to)));
        if (ok != predicted) oracleViolated = true;
        if (!ok) {
            bytes4 sel = selectorOf(reason);
            if (sel != HauntedGame.InvalidInput.selector && sel != HauntedGame.TransferFailed.selector) {
                oracleViolated = true;
            }
            if (game.credit(actor, currency) != amount) accountingViolated = true;
            return;
        }
        if (game.credit(actor, currency) != 0) accountingViolated = true;
        uint256 toAfter = nativeCurrency ? to.balance : token.balanceOf(to);
        if (toAfter != toBefore + amount) accountingViolated = true;
    }

    function flushFees() external {
        uint256 reserved0 = game.lpFees0();
        uint256 reserved1 = game.lpFees1();
        uint256 managerEth = address(manager).balance;
        uint256 managerTok = token.balanceOf(address(manager));
        bool liquid = manager.getLiquidity(poolId) != 0;
        game.flushFees();
        if (liquid) {
            if (game.lpFees0() != 0 || game.lpFees1() != 0) reservedWithLiquidity = true;
            if (address(manager).balance != managerEth + reserved0) accountingViolated = true;
            if (token.balanceOf(address(manager)) != managerTok + reserved1) accountingViolated = true;
        } else {
            if (game.lpFees0() != reserved0 || game.lpFees1() != reserved1) accountingViolated = true;
            if (address(manager).balance != managerEth) accountingViolated = true;
        }
    }

    // ------------------------------------------------------------------ the rest of the system

    struct SwapSnapshot {
        address beneficiary;
        uint256 jackpotReleases;
        uint256 jackpotReserve;
        uint256 availableAt;
        uint256 gameEth;
        uint256 gameTok;
        uint256 ticketsBefore;
    }

    function ordinarySwap(uint256 actorSeed, bool direction, uint256 amount, uint8 outcomeSeed, bool force) external {
        amount = bound(amount, 1e6, 5 ether);
        vm.startPrank(owner);
        if (force) hook.forceOutcome(HauntedHook.Outcome(outcomeSeed % 8));
        else hook.clearForcedOutcome();
        vm.stopPrank();
        // A swap on an empty pool moves the price to the limit for free (plain Uniswap behaviour,
        // covered in the hook edge suite); liquidity could then never be re-added by this handler.
        if (manager.getLiquidity(poolId) == 0) return;
        if (direction) vm.deal(address(this), address(this).balance + amount);
        SwapSnapshot memory s = SwapSnapshot({
            beneficiary: actors[actorSeed % actors.length],
            jackpotReleases: jackpot.releaseCount(),
            jackpotReserve: jackpot.reserve(),
            availableAt: jackpot.releaseAvailableAt(),
            gameEth: address(game).balance,
            gameTok: token.balanceOf(address(game)),
            ticketsBefore: game.ticketCount()
        });

        router.swap{value: direction ? amount : 0}(
            key,
            SwapParams(
                direction, -int256(amount), direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(s.beneficiary)
        );
        _checkOrdinarySwap(s);
    }

    function _checkOrdinarySwap(SwapSnapshot memory s) private {
        if (hook.swapPending() || game.executing()) accountingViolated = true;
        // The re-entering winner may have recycled its payout into a commitment: that is a legitimate
        // top-level commit during a router swap, and it must be escrowed in full.
        uint256 expectedEth = s.gameEth;
        for (uint256 id = s.ticketsBefore + 1; id <= game.ticketCount(); ++id) {
            (address player, uint128 stored,,,, bool dir, bool resolved) = game.tickets(id);
            if (player != address(reenterer) || !dir || resolved) accountingViolated = true;
            expectedEth += stored;
        }
        if (address(game).balance != expectedEth || token.balanceOf(address(game)) != s.gameTok) {
            accountingViolated = true;
        }
        if (jackpot.releaseCount() > s.jackpotReleases) {
            ++jackpotsPaid;
            uint256 paid = s.jackpotReserve - jackpot.reserve();
            if (paid > s.jackpotReserve * 300 / 10_000) jackpotCapViolated = true;
            if (block.timestamp < s.availableAt) cooldownViolated = true;
            if (s.beneficiary == address(refuser)) accountingViolated = true;
        }
    }

    function foreignUnlock(uint256 ticketSeed, uint8 which) external {
        uint256 id = bound(ticketSeed, 1, game.ticketCount() + 1);
        bytes memory inner = which % 3 == 0
            ? abi.encodeCall(HauntedGame.execute, (id))
            : which % 3 == 1 ? abi.encodeCall(HauntedGame.expire, (id)) : abi.encodeCall(HauntedGame.flushFees, ());
        uint256 reserved0 = game.lpFees0();
        uint256 reserved1 = game.lpFees1();
        uint256 gameEth = address(game).balance;
        uint256 gameTok = token.balanceOf(address(game));
        (,,,,,, bool resolvedBefore) = game.tickets(id);

        outsider.run(inner);

        if (outsider.lastOk() || selectorOf(outsider.lastReason()) != HauntedGame.ManagerUnlocked.selector) {
            foreignUnlockViolated = true;
        }
        (,,,,,, bool resolvedAfter) = game.tickets(id);
        if (
            resolvedAfter != resolvedBefore || game.lpFees0() != reserved0 || game.lpFees1() != reserved1
                || address(game).balance != gameEth || token.balanceOf(address(game)) != gameTok
        ) foreignUnlockViolated = true;
    }
}

contract HauntedGameHostileInvariantTest is HauntedFixture {
    using StateLibrary for IPoolManager;

    HostileGameHandler internal handler;
    HauntedGame internal game;

    function setUp() public override {
        super.setUp();
        game = hook.game();
        // The handler owns the only liquidity so that it can drain and refill the pool.
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(FULL_RANGE_LOWER, FULL_RANGE_UPPER, -int256(uint256(LIQUIDITY)), 0), ""
        );
        assertEq(manager.getLiquidity(poolId), 0);
        handler = new HostileGameHandler(game, hook, token, manager, jackpot, charity, swapRouter, lpRouter, key, owner);
        token.transfer(address(handler), 100_000 ether);
        vm.deal(address(handler), 10_000 ether);
        handler.init();
        assertEq(manager.getLiquidity(poolId), 1e21);
        targetContract(address(handler));
        bytes4[] memory once = new bytes4[](1);
        once[0] = HostileGameHandler.init.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: once}));
    }

    function actorsLiabilities() internal view returns (uint256 eth, uint256 tok) {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            eth += game.credit(actor, address(0));
            tok += game.credit(actor, address(token));
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    /// @dev The game holds exactly its liabilities: open escrow, reserved LP fees and player credits.
    function invariant_gameHoldsExactlyItsLiabilities() public view {
        (uint256 eth, uint256 tok) = actorsLiabilities();
        eth += game.lpFees0();
        tok += game.lpFees1();
        for (uint256 id = 1; id <= game.ticketCount(); ++id) {
            (, uint128 amount,,,, bool direction, bool resolved) = game.tickets(id);
            if (resolved) continue;
            if (direction) eth += amount;
            else tok += amount;
        }
        assertEq(address(game).balance, eth, "ETH held != ETH owed");
        assertEq(token.balanceOf(address(game)), tok, "VOID held != VOID owed");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    /// @dev A ticket resolves once, by execution only when its beacon was captured and by expiry only
    /// when it was not, and never before its target block has passed.
    function invariant_resolutionIsFinalAndMatchesCapture() public view {
        uint256 executed;
        uint256 expired;
        for (uint256 id = 1; id <= game.ticketCount(); ++id) {
            (address player,,, uint256 target,,, bool resolved) = game.tickets(id);
            assertTrue(player != address(0));
            uint8 r = handler.resolution(id);
            assertEq(resolved, r != 0, "resolved flag disagrees with the handler's record");
            if (r == 1) {
                assertTrue(game.captured(target), "executed without captured entropy");
                assertGt(block.number, target);
                ++executed;
            } else if (r == 2) {
                assertFalse(game.captured(target), "expired although entropy was captured");
                assertGt(block.number, target);
                ++expired;
            }
        }
        assertEq(executed, handler.executedCount());
        assertEq(expired, handler.expiredCount());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    /// @dev Every per-call check the handler performs held: the contract's own quotes predicted each
    /// outcome, fees stayed within the 5% ceiling, the money went where the design says, nothing
    /// stayed reserved while the pool could receive it, and foreign unlocks changed nothing.
    function invariant_handlerObservedNoViolation() public view {
        assertFalse(handler.oracleViolated(), "a call succeeded or failed against the contract's own quote");
        assertFalse(handler.feeCapViolated(), "a drawn fee exceeded the 5% ceiling");
        assertFalse(handler.accountingViolated(), "a settlement moved value somewhere unexpected");
        assertFalse(handler.reservedWithLiquidity(), "fees stayed reserved while the pool had liquidity");
        assertFalse(handler.foreignUnlockViolated(), "a nested-unlock call was not refused cleanly");
        assertFalse(handler.jackpotCapViolated(), "a jackpot exceeded 3% of the reserve");
        assertFalse(handler.cooldownViolated(), "a jackpot paid inside the cooldown");
        assertEq(handler.reenterer().settlementsAccepted(), 0, "a settlement succeeded from inside a payout");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_vaultsAndSupplyConserved() public view {
        assertEq(jackpot.reserve() + jackpot.totalReleased(), handler.jackpotFunded(), "jackpot ETH leaked");
        assertEq(charity.reserve() + charity.totalReleased(), handler.charityFunded(), "charity ETH leaked");
        assertEq(token.totalSupply(), token.SUPPLY());
        assertEq(token.balanceOf(hook.DEAD()), hook.totalBurned());
        assertEq(address(hook).balance, 0, "the hook never holds ETH");
        assertFalse(hook.swapPending());
        assertFalse(game.executing());
        assertLe(hook.corruption(), hook.MAX_CORRUPTION());
    }
}
