// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HauntedVault} from "../src/HauntedVault.sol";
import {JackpotVault} from "../src/JackpotVault.sol";
import {CharityVault} from "../src/CharityVault.sol";

contract RejectingReceiver {
    receive() external payable {
        revert("no thanks");
    }
}

/// @dev Holds PAYER_ROLE and tries to pay itself again from inside the ETH transfer.
contract ReentrantPayer {
    JackpotVault internal vault;
    bool public reentered;
    bytes public innerRevert;

    constructor(JackpotVault v) {
        vault = v;
    }

    function attack() external returns (uint256) {
        return vault.payout(address(this));
    }

    /// @dev Swallows the inner failure so the outer payout completes and the reason can be inspected.
    receive() external payable {
        reentered = true;
        try vault.payout(address(this)) {}
        catch (bytes memory reason) {
            innerRevert = reason;
        }
    }
}

contract VaultsTest is Test {
    JackpotVault internal jackpot;
    CharityVault internal charity;
    address internal owner = makeAddr("owner");
    address internal hook = makeAddr("hook");
    address internal charityWallet = makeAddr("charityWallet");
    address internal stranger = makeAddr("stranger");
    address internal winner = makeAddr("winner");

    bytes32 internal PAYER;
    bytes32 internal SIGNALER;
    bytes32 internal PAUSER;
    bytes32 internal ADMIN;

    function setUp() public {
        jackpot = new JackpotVault(owner, 300, 10 minutes);
        charity = new CharityVault(owner, charityWallet, 100, 1 hours);
        PAYER = jackpot.PAYER_ROLE();
        SIGNALER = charity.SIGNALER_ROLE();
        PAUSER = jackpot.PAUSER_ROLE();
        ADMIN = jackpot.DEFAULT_ADMIN_ROLE();
        vm.startPrank(owner);
        jackpot.grantRole(PAYER, hook);
        charity.grantRole(SIGNALER, hook);
        vm.stopPrank();
        vm.warp(1_000_000);
    }

    // ------------------------------------------------------------------ construction

    function test_constructorWiring() public view {
        assertEq(jackpot.MAX_RELEASE_BPS(), 300);
        assertEq(jackpot.MAX_PAYOUT_BPS(), 300);
        assertEq(charity.MAX_RELEASE_BPS(), 100);
        assertEq(charity.MAX_DONATION_BPS(), 100);
        assertTrue(jackpot.hasRole(ADMIN, owner));
        assertTrue(jackpot.hasRole(PAUSER, owner));
        assertFalse(jackpot.hasRole(PAYER, owner));
        assertEq(charity.charity(), charityWallet);
        assertEq(jackpot.releaseAvailableAt(), 0);
    }

    function test_constructorRejectsBadParams() public {
        vm.expectRevert(HauntedVault.ZeroAddress.selector);
        new JackpotVault(address(0), 300, 1);
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.InvalidReleaseBps.selector, 0, 300));
        new JackpotVault(owner, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.InvalidReleaseBps.selector, 301, 300));
        new JackpotVault(owner, 301, 1);
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.InvalidCooldown.selector, 30 days + 1, 30 days));
        new JackpotVault(owner, 300, 30 days + 1);
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.InvalidReleaseBps.selector, 101, 100));
        new CharityVault(owner, charityWallet, 101, 1);
        vm.expectRevert(HauntedVault.ZeroAddress.selector);
        new CharityVault(owner, address(0), 100, 1);
    }

    // ------------------------------------------------------------------ funding

    function test_fundingIsPermissionless() public {
        vm.deal(stranger, 3 ether);
        vm.prank(stranger);
        vm.expectEmit(address(jackpot));
        emit HauntedVault.Funded(stranger, 1 ether, 1 ether);
        (bool ok,) = address(jackpot).call{value: 1 ether}("");
        assertTrue(ok);
        vm.prank(stranger);
        jackpot.fund{value: 2 ether}();
        assertEq(jackpot.reserve(), 3 ether);
        assertEq(jackpot.nextReleaseAmount(), 0.09 ether);
    }

    // ------------------------------------------------------------------ permissions

    function test_payoutRequiresPayerRole() public {
        vm.deal(address(jackpot), 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, PAYER)
        );
        vm.prank(stranger);
        jackpot.payout(winner);
        // the admin does not hold the payer role either
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, PAYER));
        vm.prank(owner);
        jackpot.payout(winner);
    }

    function test_donateRequiresSignalerRole() public {
        vm.deal(address(charity), 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, SIGNALER)
        );
        vm.prank(stranger);
        charity.donate();
    }

    function test_adminOnlySetters() public {
        vm.startPrank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN)
        );
        jackpot.setReleaseBps(100);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN)
        );
        jackpot.setCooldown(1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN)
        );
        charity.setCharity(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, PAUSER)
        );
        jackpot.pause();
        vm.stopPrank();

        vm.startPrank(owner);
        jackpot.setReleaseBps(100);
        jackpot.setCooldown(1 days);
        charity.setCharity(stranger);
        vm.stopPrank();
        assertEq(jackpot.releaseBps(), 100);
        assertEq(jackpot.cooldown(), 1 days);
        assertEq(charity.charity(), stranger);
    }

    function test_settersRejectOutOfRange() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.InvalidReleaseBps.selector, 301, 300));
        jackpot.setReleaseBps(301);
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.InvalidReleaseBps.selector, 0, 300));
        jackpot.setReleaseBps(0);
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.InvalidCooldown.selector, 31 days, 30 days));
        jackpot.setCooldown(31 days);
        vm.expectRevert(HauntedVault.ZeroAddress.selector);
        charity.setCharity(address(0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ caps

    function test_jackpotPaysExactlyThreePercent() public {
        vm.deal(address(jackpot), 10 ether);
        vm.prank(hook);
        vm.expectEmit(address(jackpot));
        emit HauntedVault.Released(winner, 0.3 ether, 10 ether, 1);
        vm.expectEmit(address(jackpot));
        emit JackpotVault.JackpotPaid(winner, 0.3 ether, 10 ether);
        uint256 paid = jackpot.payout(winner);
        assertEq(paid, 0.3 ether);
        assertEq(winner.balance, 0.3 ether);
        assertEq(jackpot.reserve(), 9.7 ether);
        assertEq(jackpot.totalReleased(), 0.3 ether);
        assertEq(jackpot.releaseCount(), 1);
        assertEq(jackpot.lastReleaseAt(), block.timestamp);
    }

    function test_charityDonatesExactlyOnePercent() public {
        vm.deal(address(charity), 10 ether);
        vm.prank(hook);
        vm.expectEmit(address(charity));
        emit CharityVault.Donated(charityWallet, 0.1 ether, 10 ether);
        uint256 paid = charity.donate();
        assertEq(paid, 0.1 ether);
        assertEq(charityWallet.balance, 0.1 ether);
        assertEq(charity.reserve(), 9.9 ether);
    }

    function testFuzz_jackpotNeverExceedsCap(uint256 reserve, uint256 bps) public {
        reserve = bound(reserve, 0, 1e30);
        bps = bound(bps, 1, 300);
        vm.prank(owner);
        jackpot.setReleaseBps(bps);
        vm.deal(address(jackpot), reserve);
        uint256 cap = reserve * 300 / 10_000;
        if (reserve * bps / 10_000 == 0) {
            vm.prank(hook);
            vm.expectRevert(HauntedVault.NothingToRelease.selector);
            jackpot.payout(winner);
            return;
        }
        vm.prank(hook);
        uint256 paid = jackpot.payout(winner);
        assertLe(paid, cap);
        assertEq(paid, reserve * bps / 10_000);
        assertEq(paid + jackpot.reserve(), reserve);
    }

    function testFuzz_charityNeverExceedsCap(uint256 reserve, uint256 bps) public {
        reserve = bound(reserve, 10_000, 1e30);
        bps = bound(bps, 1, 100);
        vm.prank(owner);
        charity.setReleaseBps(bps);
        vm.deal(address(charity), reserve);
        vm.prank(hook);
        uint256 paid = charity.donate();
        assertLe(paid, reserve / 100);
        assertEq(paid, reserve * bps / 10_000);
    }

    function test_emptyVaultReverts() public {
        vm.prank(hook);
        vm.expectRevert(HauntedVault.NothingToRelease.selector);
        jackpot.payout(winner);
        assertFalse(jackpot.canRelease());
    }

    // ------------------------------------------------------------------ cooldowns

    function test_cooldownBlocksSecondPayout() public {
        vm.deal(address(jackpot), 10 ether);
        vm.startPrank(hook);
        jackpot.payout(winner);
        uint256 availableAt = block.timestamp + 10 minutes;
        assertEq(jackpot.releaseAvailableAt(), availableAt);
        assertFalse(jackpot.canRelease());

        vm.expectRevert(abi.encodeWithSelector(HauntedVault.CooldownActive.selector, availableAt));
        jackpot.payout(winner);

        vm.warp(availableAt - 1);
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.CooldownActive.selector, availableAt));
        jackpot.payout(winner);

        vm.warp(availableAt);
        assertTrue(jackpot.canRelease());
        uint256 paid = jackpot.payout(winner);
        assertEq(paid, 9.7 ether * 300 / 10_000);
        vm.stopPrank();
    }

    function testFuzz_cooldownRespected(uint256 cooldown, uint256 elapsed) public {
        cooldown = bound(cooldown, 0, 30 days);
        elapsed = bound(elapsed, 0, 60 days);
        vm.prank(owner);
        jackpot.setCooldown(cooldown);
        vm.deal(address(jackpot), 100 ether);
        vm.prank(hook);
        jackpot.payout(winner);
        uint256 first = block.timestamp;
        vm.warp(first + elapsed);
        vm.prank(hook);
        if (elapsed < cooldown) {
            vm.expectRevert(abi.encodeWithSelector(HauntedVault.CooldownActive.selector, first + cooldown));
            jackpot.payout(winner);
        } else {
            jackpot.payout(winner);
            assertEq(jackpot.releaseCount(), 2);
        }
    }

    function test_charityCooldown() public {
        vm.deal(address(charity), 10 ether);
        vm.startPrank(hook);
        charity.donate();
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.CooldownActive.selector, block.timestamp + 1 hours));
        charity.donate();
        vm.warp(block.timestamp + 1 hours);
        charity.donate();
        vm.stopPrank();
        assertEq(charity.releaseCount(), 2);
    }

    // ------------------------------------------------------------------ pause

    function test_pauseBlocksReleasesNotFunding() public {
        vm.deal(address(jackpot), 10 ether);
        vm.prank(owner);
        jackpot.pause();
        assertTrue(jackpot.paused());
        assertFalse(jackpot.canRelease());

        vm.prank(hook);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        jackpot.payout(winner);

        jackpot.fund{value: 1 ether}();
        assertEq(jackpot.reserve(), 11 ether);

        vm.prank(owner);
        jackpot.unpause();
        vm.prank(hook);
        assertEq(jackpot.payout(winner), 0.33 ether);
    }

    function test_charityPause() public {
        vm.deal(address(charity), 10 ether);
        vm.prank(owner);
        charity.pause();
        vm.prank(hook);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        charity.donate();
    }

    // ------------------------------------------------------------------ transfer failures and reentrancy

    function test_rejectingWinnerReverts() public {
        RejectingReceiver r = new RejectingReceiver();
        vm.deal(address(jackpot), 10 ether);
        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.TransferFailed.selector, address(r), 0.3 ether));
        jackpot.payout(address(r));
        assertEq(jackpot.reserve(), 10 ether);
        assertEq(jackpot.lastReleaseAt(), 0);
    }

    function test_reentrantPayoutIsBlocked() public {
        ReentrantPayer attacker = new ReentrantPayer(jackpot);
        vm.prank(owner);
        jackpot.grantRole(PAYER, address(attacker));
        vm.deal(address(jackpot), 10 ether);

        uint256 paid = attacker.attack();

        assertEq(paid, 0.3 ether, "outer payout completes once");
        assertTrue(attacker.reentered(), "the attacker did re-enter");
        assertEq(
            attacker.innerRevert(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "the nested payout hit the guard"
        );
        assertEq(address(attacker).balance, 0.3 ether);
        assertEq(jackpot.reserve(), 9.7 ether);
        assertEq(jackpot.releaseCount(), 1);
    }

    function test_zeroRecipientReverts() public {
        vm.deal(address(jackpot), 10 ether);
        vm.prank(hook);
        vm.expectRevert(HauntedVault.ZeroAddress.selector);
        jackpot.payout(address(0));
    }

    function test_noAdminWithdrawalSelectors() public {
        vm.deal(address(jackpot), 10 ether);
        string[5] memory sigs =
            ["withdraw(uint256)", "withdraw()", "sweep(address)", "rescue(address,uint256)", "emergencyWithdraw()"];
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(jackpot).call(abi.encodeWithSignature(sigs[i], owner, uint256(1 ether)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(jackpot.reserve(), 10 ether);
    }
}
