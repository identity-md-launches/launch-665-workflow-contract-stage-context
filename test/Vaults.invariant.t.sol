// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JackpotVault} from "../src/JackpotVault.sol";
import {CharityVault} from "../src/CharityVault.sol";
import {HauntedVault} from "../src/HauntedVault.sol";

/// @dev Drives one vault with funding, releases, pauses, warps and admin changes, and records
/// every rule violation it can observe at call time.
contract VaultHandler is Test {
    HauntedVault public vault;
    bool public isJackpot;
    address public admin;
    address[] public winners;

    uint256 public funded;
    uint256 public releases;
    bool public capViolated;
    bool public cooldownViolated;
    bool public pauseViolated;
    bool public bpsOutOfRange;

    constructor(HauntedVault v, bool jackpot_, address admin_) {
        vault = v;
        isJackpot = jackpot_;
        admin = admin_;
        for (uint256 i; i < 4; ++i) {
            winners.push(makeAddr(string.concat("winner", vm.toString(i))));
        }
    }

    receive() external payable {}

    function fund(uint256 amount) external {
        amount = bound(amount, 0, 1000 ether);
        vm.deal(address(this), amount);
        vault.fund{value: amount}();
        funded += amount;
    }

    function release(uint256 winnerSeed) external {
        address winner = winners[winnerSeed % winners.length];
        uint256 reserveBefore = vault.reserve();
        uint256 lastBefore = vault.lastReleaseAt();
        uint256 cooldown = vault.cooldown();
        bool paused = vault.paused();

        bool ok;
        uint256 amount;
        if (isJackpot) {
            try JackpotVault(payable(address(vault))).payout(winner) returns (uint256 a) {
                ok = true;
                amount = a;
            } catch {}
        } else {
            try CharityVault(payable(address(vault))).donate() returns (uint256 a) {
                ok = true;
                amount = a;
            } catch {}
        }
        if (!ok) return;
        releases++;
        if (amount > reserveBefore * vault.MAX_RELEASE_BPS() / 10_000) capViolated = true;
        if (amount != reserveBefore * vault.releaseBps() / 10_000) capViolated = true;
        if (lastBefore != 0 && block.timestamp < lastBefore + cooldown) cooldownViolated = true;
        if (paused) pauseViolated = true;
    }

    function warp(uint256 by) external {
        by = bound(by, 0, 3 days);
        vm.warp(block.timestamp + by);
    }

    function setPaused(bool p) external {
        if (p == vault.paused()) return;
        vm.prank(admin);
        if (p) vault.pause();
        else vault.unpause();
    }

    function setReleaseBps(uint256 bps) external {
        bps = bound(bps, 1, vault.MAX_RELEASE_BPS());
        vm.prank(admin);
        vault.setReleaseBps(bps);
    }

    function setCooldown(uint256 cooldown) external {
        cooldown = bound(cooldown, 0, 30 days);
        vm.prank(admin);
        vault.setCooldown(cooldown);
    }

    function winnerBalances() external view returns (uint256 total) {
        for (uint256 i; i < winners.length; ++i) {
            total += winners[i].balance;
        }
    }
}

abstract contract VaultInvariantBase is Test {
    HauntedVault internal vault;
    VaultHandler internal handler;
    address internal admin = makeAddr("admin");
    address internal charityWallet = makeAddr("charityWallet");

    function invariant_fundsAreConserved() public view {
        assertEq(vault.reserve() + vault.totalReleased(), handler.funded());
    }

    function invariant_everyReleaseWithinCap() public view {
        assertFalse(handler.capViolated());
    }

    function invariant_cooldownRespected() public view {
        assertFalse(handler.cooldownViolated());
    }

    function invariant_noReleaseWhilePaused() public view {
        assertFalse(handler.pauseViolated());
    }

    function invariant_configWithinBounds() public view {
        assertGt(vault.releaseBps(), 0);
        assertLe(vault.releaseBps(), vault.MAX_RELEASE_BPS());
        assertLe(vault.cooldown(), vault.MAX_COOLDOWN());
        assertEq(vault.releaseCount(), handler.releases());
    }
}

contract JackpotVaultInvariantTest is VaultInvariantBase {
    function setUp() public {
        vm.warp(1_000_000);
        JackpotVault jackpot = new JackpotVault(admin, 300, 10 minutes);
        vault = jackpot;
        handler = new VaultHandler(jackpot, true, admin);
        bytes32 payer = jackpot.PAYER_ROLE();
        vm.prank(admin);
        jackpot.grantRole(payer, address(handler));
        targetContract(address(handler));
    }

    function invariant_winnersReceivedEverything() public view {
        assertEq(handler.winnerBalances(), vault.totalReleased());
        assertEq(vault.MAX_RELEASE_BPS(), 300);
    }
}

contract CharityVaultInvariantTest is VaultInvariantBase {
    function setUp() public {
        vm.warp(1_000_000);
        CharityVault charity = new CharityVault(admin, charityWallet, 100, 1 hours);
        vault = charity;
        handler = new VaultHandler(charity, false, admin);
        bytes32 signaler = charity.SIGNALER_ROLE();
        vm.prank(admin);
        charity.grantRole(signaler, address(handler));
        targetContract(address(handler));
    }

    function invariant_charityReceivedEverything() public view {
        assertEq(charityWallet.balance, vault.totalReleased());
        assertEq(vault.MAX_RELEASE_BPS(), 100);
    }
}
