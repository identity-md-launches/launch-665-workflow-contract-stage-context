// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HauntedFixture} from "./utils/HauntedFixture.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {JackpotVault} from "../src/JackpotVault.sol";
import {CharityVault} from "../src/CharityVault.sol";
import {HauntedHook} from "../src/HauntedHook.sol";

/// @dev Random swaps in both directions with random prevrandao, hookData beneficiaries, funding,
/// time warps and owner test controls. Records vault-rule violations observed around each swap.
contract HookHandler is Test {
    HauntedHook public hook;
    LaunchToken public token;
    JackpotVault public jackpot;
    CharityVault public charity;
    PoolSwapTest public router;
    PoolKey internal key;
    address public owner;
    address[] public actors;

    uint256 public hoardFunded;
    uint256 public jackpotFunded;
    uint256 public charityFunded;
    uint256 public swaps;
    bool public capViolated;
    bool public cooldownViolated;

    constructor(
        HauntedHook h,
        LaunchToken t,
        JackpotVault j,
        CharityVault c,
        PoolSwapTest r,
        PoolKey memory k,
        address owner_
    ) {
        hook = h;
        token = t;
        jackpot = j;
        charity = c;
        router = r;
        key = k;
        owner = owner_;
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
        token.approve(address(router), type(uint256).max);
        token.approve(address(hook), type(uint256).max);
    }

    receive() external payable {}

    struct VaultSnapshot {
        uint256 reserve;
        uint256 released;
        uint256 last;
        uint256 cooldown;
    }

    function snapshot(JackpotVault j, CharityVault c)
        internal
        view
        returns (VaultSnapshot memory js, VaultSnapshot memory cs)
    {
        js = VaultSnapshot(j.reserve(), j.totalReleased(), j.lastReleaseAt(), j.cooldown());
        cs = VaultSnapshot(c.reserve(), c.totalReleased(), c.lastReleaseAt(), c.cooldown());
    }

    function check(VaultSnapshot memory before, uint256 releasedNow, uint256 maxBps) internal {
        uint256 paid = releasedNow - before.released;
        if (paid == 0) return;
        if (paid > before.reserve * maxBps / 10_000) capViolated = true;
        if (before.last != 0 && block.timestamp < before.last + before.cooldown) cooldownViolated = true;
    }

    function swap(bool zeroForOne, uint256 amount, uint256 prevrandao, uint8 actorSeed, bool nameActor) external {
        amount = bound(amount, 1e12, 5 ether);
        vm.prevrandao(bytes32(prevrandao));
        bytes memory hookData = nameActor ? abi.encode(actors[actorSeed % actors.length]) : bytes("");
        (VaultSnapshot memory js, VaultSnapshot memory cs) = snapshot(jackpot, charity);

        doSwap(zeroForOne, amount, hookData);
        swaps++;

        check(js, jackpot.totalReleased(), 300);
        check(cs, charity.totalReleased(), 100);
    }

    function doSwap(bool zeroForOne, uint256 amount, bytes memory hookData) internal {
        uint256 value = zeroForOne ? amount : 0;
        vm.deal(address(this), address(this).balance + value);
        router.swap{value: value}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function fundHoard(uint256 amount) external {
        amount = bound(amount, 0, 1e21);
        if (amount > token.balanceOf(address(this))) return;
        hook.fundHoard(amount);
        hoardFunded += amount;
    }

    function fundJackpot(uint256 amount) external {
        amount = bound(amount, 0, 50 ether);
        vm.deal(address(this), address(this).balance + amount);
        jackpot.fund{value: amount}();
        jackpotFunded += amount;
    }

    function fundCharity(uint256 amount) external {
        amount = bound(amount, 0, 50 ether);
        vm.deal(address(this), address(this).balance + amount);
        charity.fund{value: amount}();
        charityFunded += amount;
    }

    function warp(uint256 by) external {
        by = bound(by, 0, 2 days);
        vm.warp(block.timestamp + by);
    }

    function force(uint8 outcome, bool active) external {
        vm.prank(owner);
        if (active) hook.forceOutcome(HauntedHook.Outcome(outcome % 8));
        else hook.clearForcedOutcome();
    }

    function setBurnBps(uint256 bps) external {
        bps = bound(bps, 0, 500);
        vm.prank(owner);
        hook.setBurnBps(bps);
    }

    function pauseJackpot(bool p) external {
        if (p == jackpot.paused()) return;
        vm.prank(owner);
        if (p) jackpot.pause();
        else jackpot.unpause();
    }

    function actorBalances() external view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += actors[i].balance;
        }
    }
}

contract HauntedHookInvariantTest is HauntedFixture {
    HookHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.warp(1_000_000);
        handler = new HookHandler(hook, token, jackpot, charity, swapRouter, key, owner);
        token.transfer(address(handler), 10_000_000 ether);
        targetContract(address(handler));
    }

    function invariant_noSwapLeftPending() public view {
        assertFalse(hook.swapPending());
    }

    function invariant_corruptionBounded() public view {
        assertLe(hook.corruption(), hook.MAX_CORRUPTION());
        assertLe(hook.burnBps(), hook.MAX_BURN_BPS());
        assertLt(hook.loreUnlockedMask(), 1 << hook.LORE_FRAGMENTS());
    }

    function invariant_burnAccounting() public view {
        assertEq(hook.totalBurned(), token.balanceOf(hook.DEAD()));
        assertEq(hook.hoard() + hook.totalBurned(), handler.hoardFunded());
    }

    function invariant_voidSupplyConserved() public view {
        uint256 held = token.balanceOf(address(this)) + token.balanceOf(address(handler))
            + token.balanceOf(address(manager)) + hook.hoard() + token.balanceOf(hook.DEAD());
        assertEq(held, token.totalSupply());
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function invariant_vaultFundsConserved() public view {
        assertEq(jackpot.reserve() + jackpot.totalReleased(), handler.jackpotFunded());
        assertEq(charity.reserve() + charity.totalReleased(), handler.charityFunded());
        assertEq(charityWallet.balance, charity.totalReleased());
        // Missing beneficiaries must never redirect a jackpot to the router.
        assertEq(address(swapRouter).balance, 0);
        assertEq(handler.actorBalances(), jackpot.totalReleased());
    }

    function invariant_vaultRulesHeldAroundSwaps() public view {
        assertFalse(handler.capViolated());
        assertFalse(handler.cooldownViolated());
    }

    function invariant_poolCountAndFee() public view {
        assertEq(hook.hauntedPools(), 1);
        assertTrue(hook.haunted(poolId));
        assertEq(lpFee(), 3000, "stored dynamic fee is never changed after init");
    }
}
