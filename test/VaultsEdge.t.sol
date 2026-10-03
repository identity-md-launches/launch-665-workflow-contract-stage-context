// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {HauntedVault} from "../src/HauntedVault.sol";
import {JackpotVault} from "../src/JackpotVault.sol";
import {CharityVault} from "../src/CharityVault.sol";

/// @dev Refuses every ETH transfer.
contract RefusingCharity {
    receive() external payable {
        revert("closed");
    }
}

/// @dev Burns all forwarded gas inside receive so the vault's low-level call fails without a reason.
contract GasGreedyWinner {
    uint256 public sink;

    receive() external payable {
        while (true) {
            sink++;
        }
    }
}

/// @notice Edge inputs and failure paths of the vaults beyond the happy path: rounding dust, zero
/// cooldown, pause interacting with cooldown, role churn, re-pointed charities, hostile recipients,
/// and `canRelease` as an exact oracle of `_release`.
contract VaultsEdgeTest is Test {
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

    // ------------------------------------------------------------------ rounding at the bottom

    function test_dustReserveBelowOneWeiShareCannotRelease() public {
        // 33 wei * 300 / 10_000 rounds to 0: nothing to release, and canRelease says so.
        vm.deal(address(jackpot), 33);
        assertEq(jackpot.nextReleaseAmount(), 0);
        assertFalse(jackpot.canRelease());
        vm.prank(hook);
        vm.expectRevert(HauntedVault.NothingToRelease.selector);
        jackpot.payout(winner);
        assertEq(jackpot.lastReleaseAt(), 0, "a failed release leaves no trace");

        // 34 wei is the first reserve that pays anything: exactly 1 wei.
        vm.deal(address(jackpot), 34);
        assertEq(jackpot.nextReleaseAmount(), 1);
        assertTrue(jackpot.canRelease());
        vm.prank(hook);
        assertEq(jackpot.payout(winner), 1);
        assertEq(winner.balance, 1);
        assertEq(jackpot.reserve(), 33);
    }

    function test_charityDustBoundary() public {
        vm.deal(address(charity), 99);
        vm.prank(hook);
        vm.expectRevert(HauntedVault.NothingToRelease.selector);
        charity.donate();
        vm.deal(address(charity), 100);
        vm.prank(hook);
        assertEq(charity.donate(), 1);
    }

    function testFuzz_payoutEqualsQuotedNextReleaseAmount(uint256 reserve, uint256 bps) public {
        reserve = bound(reserve, 0, 1e30);
        bps = bound(bps, 1, 300);
        vm.prank(owner);
        jackpot.setReleaseBps(bps);
        vm.deal(address(jackpot), reserve);
        uint256 quoted = jackpot.nextReleaseAmount();
        assertLe(quoted, reserve * 300 / 10_000, "quote within the 3% cap");
        vm.prank(hook);
        if (quoted == 0) {
            vm.expectRevert(HauntedVault.NothingToRelease.selector);
            jackpot.payout(winner);
        } else {
            assertEq(jackpot.payout(winner), quoted, "paid exactly what was quoted");
            assertEq(jackpot.reserve(), reserve - quoted);
        }
    }

    // ------------------------------------------------------------------ canRelease as an oracle

    /// @dev `canRelease()` must be true exactly when a payout to an accepting recipient succeeds.
    function testFuzz_canReleaseIsAnExactOracle(
        uint256 reserve,
        uint256 bps,
        uint256 cooldown,
        uint256 elapsed,
        bool paused,
        bool priorRelease
    ) public {
        reserve = bound(reserve, 0, 1e24);
        bps = bound(bps, 1, 300);
        cooldown = bound(cooldown, 1, 30 days);
        elapsed = bound(elapsed, 0, 45 days);

        vm.startPrank(owner);
        jackpot.setReleaseBps(bps);
        jackpot.setCooldown(cooldown);
        vm.stopPrank();

        if (priorRelease) {
            vm.deal(address(jackpot), 1 ether);
            vm.prank(hook);
            jackpot.payout(winner);
        }
        vm.warp(block.timestamp + elapsed);
        vm.deal(address(jackpot), reserve);
        if (paused) {
            vm.prank(owner);
            jackpot.pause();
        }

        bool predicted = jackpot.canRelease();
        vm.prank(hook);
        (bool ok,) = address(jackpot).call(abi.encodeCall(jackpot.payout, (winner)));
        assertEq(ok, predicted, "canRelease disagrees with payout");
    }

    // ------------------------------------------------------------------ cooldown edges

    function test_zeroCooldownRejectedAndMinimumCooldownPreventsBackToBackPayouts() public {
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.InvalidCooldown.selector, 0, 30 days));
        vm.prank(owner);
        jackpot.setCooldown(0);
        assertEq(jackpot.cooldown(), 10 minutes, "rejected setting leaves cooldown unchanged");
        vm.prank(owner);
        jackpot.setCooldown(1);
        vm.deal(address(jackpot), 10 ether);
        vm.startPrank(hook);
        assertEq(jackpot.payout(winner), 0.3 ether);
        uint256 availableAt = block.timestamp + 1;
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.CooldownActive.selector, availableAt));
        jackpot.payout(winner);
        assertEq(jackpot.releaseCount(), 1);
        assertEq(jackpot.reserve(), 9.7 ether);
        vm.warp(availableAt);
        assertEq(jackpot.payout(winner), 0.291 ether, "3% of the reduced reserve");
        vm.warp(availableAt + 1);
        assertEq(jackpot.payout(winner), 0.28227 ether);
        vm.stopPrank();
        assertEq(jackpot.releaseCount(), 3);
        assertEq(jackpot.releaseAvailableAt(), block.timestamp + 1);
        assertFalse(jackpot.canRelease());
        assertEq(jackpot.reserve() + jackpot.totalReleased(), 10 ether);
    }

    function test_maxCooldownBoundaryAccepted() public {
        vm.prank(owner);
        jackpot.setCooldown(30 days);
        vm.deal(address(jackpot), 10 ether);
        vm.prank(hook);
        jackpot.payout(winner);
        assertEq(jackpot.releaseAvailableAt(), block.timestamp + 30 days);
        vm.warp(block.timestamp + 30 days - 1);
        assertFalse(jackpot.canRelease());
        vm.warp(block.timestamp + 1);
        assertTrue(jackpot.canRelease());
    }

    function test_pauseDoesNotResetOrExtendCooldown() public {
        vm.deal(address(jackpot), 10 ether);
        vm.prank(hook);
        jackpot.payout(winner);
        uint256 availableAt = block.timestamp + 10 minutes;

        vm.prank(owner);
        jackpot.pause();
        vm.warp(availableAt - 1);
        vm.prank(owner);
        jackpot.unpause();
        // Cooldown still running: unpausing did not make a release available earlier.
        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.CooldownActive.selector, availableAt));
        jackpot.payout(winner);

        // Nor did pausing push the available time later.
        vm.warp(availableAt);
        vm.prank(hook);
        jackpot.payout(winner);
        assertEq(jackpot.releaseCount(), 2);
    }

    function test_shorteningCooldownAppliesRetroactively() public {
        vm.deal(address(jackpot), 10 ether);
        vm.prank(hook);
        jackpot.payout(winner);
        vm.warp(block.timestamp + 1 minutes);
        assertFalse(jackpot.canRelease());
        vm.prank(owner);
        jackpot.setCooldown(30 seconds);
        assertTrue(jackpot.canRelease(), "cooldown is measured against the current setting");
    }

    function test_releaseBpsChangeAppliesToNextPayoutOnly() public {
        vm.deal(address(jackpot), 10 ether);
        vm.prank(owner);
        jackpot.setReleaseBps(150);
        vm.prank(hook);
        assertEq(jackpot.payout(winner), 0.15 ether, "1.5% after the change");
        assertEq(jackpot.MAX_RELEASE_BPS(), 300, "the cap itself is immutable");
    }

    // ------------------------------------------------------------------ pause edges

    function test_pauseTwiceAndUnpauseWhenRunningRevert() public {
        vm.startPrank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        jackpot.unpause();
        jackpot.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        jackpot.pause();
        vm.stopPrank();
    }

    function test_pausedVaultStillAcceptsFundingAndAdminChanges() public {
        vm.prank(owner);
        charity.pause();
        charity.fund{value: 1 ether}();
        (bool ok,) = address(charity).call{value: 1 ether}("");
        assertTrue(ok);
        vm.startPrank(owner);
        charity.setReleaseBps(50);
        charity.setCooldown(1 days);
        charity.setCharity(stranger);
        vm.stopPrank();
        assertEq(charity.reserve(), 2 ether);
        assertEq(charity.charity(), stranger);
    }

    // ------------------------------------------------------------------ roles

    function test_revokedPayerCanNoLongerPay() public {
        vm.deal(address(jackpot), 10 ether);
        vm.prank(owner);
        jackpot.revokeRole(PAYER, hook);
        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, hook, PAYER));
        jackpot.payout(winner);
        assertEq(jackpot.reserve(), 10 ether);
    }

    function test_twoPayersShareOneCooldown() public {
        address secondPayer = makeAddr("secondPayer");
        vm.prank(owner);
        jackpot.grantRole(PAYER, secondPayer);
        vm.deal(address(jackpot), 10 ether);
        vm.prank(hook);
        jackpot.payout(winner);
        vm.prank(secondPayer);
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.CooldownActive.selector, block.timestamp + 10 minutes));
        jackpot.payout(stranger);
    }

    function test_onlyAdminGrantsRoles() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN)
        );
        jackpot.grantRole(PAYER, stranger);
        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, hook, ADMIN));
        jackpot.grantRole(PAYER, stranger);
        assertFalse(jackpot.hasRole(PAYER, stranger));
    }

    function test_renouncedAdminLosesSettersButPauserRoleIsSeparate() public {
        vm.startPrank(owner);
        jackpot.renounceRole(ADMIN, owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, ADMIN));
        jackpot.setReleaseBps(100);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, ADMIN));
        jackpot.grantRole(PAYER, owner);
        // PAUSER_ROLE was granted separately and survives the admin renounce.
        jackpot.pause();
        jackpot.unpause();
        jackpot.renounceRole(PAUSER, owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, PAUSER));
        jackpot.pause();
        vm.stopPrank();
        // The payer keeps working: releases do not depend on an admin existing.
        vm.deal(address(jackpot), 10 ether);
        vm.prank(hook);
        assertEq(jackpot.payout(winner), 0.3 ether);
    }

    // ------------------------------------------------------------------ charity re-pointing

    function test_donationGoesToTheCharitySetAtDonationTime() public {
        vm.deal(address(charity), 10 ether);
        vm.prank(owner);
        vm.expectEmit(address(charity));
        emit CharityVault.CharityUpdated(charityWallet, stranger);
        charity.setCharity(stranger);
        vm.prank(hook);
        vm.expectEmit(address(charity));
        emit CharityVault.Donated(stranger, 0.1 ether, 10 ether);
        charity.donate();
        assertEq(stranger.balance, 0.1 ether);
        assertEq(charityWallet.balance, 0, "the previous charity receives nothing");
    }

    function test_refusingCharityDoesNotConsumeCooldownOrAccounting() public {
        RefusingCharity refusing = new RefusingCharity();
        vm.deal(address(charity), 10 ether);
        vm.prank(owner);
        charity.setCharity(address(refusing));
        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.TransferFailed.selector, address(refusing), 0.1 ether));
        charity.donate();
        assertEq(charity.reserve(), 10 ether);
        assertEq(charity.totalReleased(), 0);
        assertEq(charity.releaseCount(), 0);
        assertEq(charity.lastReleaseAt(), 0);

        // Re-pointing to a working address recovers immediately.
        vm.prank(owner);
        charity.setCharity(charityWallet);
        vm.prank(hook);
        assertEq(charity.donate(), 0.1 ether);
    }

    // ------------------------------------------------------------------ hostile recipients

    function test_gasGreedyWinnerFailsWithoutDrainingTheVault() public {
        GasGreedyWinner greedy = new GasGreedyWinner();
        vm.deal(address(jackpot), 10 ether);
        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(HauntedVault.TransferFailed.selector, address(greedy), 0.3 ether));
        jackpot.payout(address(greedy));
        assertEq(jackpot.reserve(), 10 ether);
        assertEq(jackpot.lastReleaseAt(), 0);
    }

    function test_winnerCanBeTheAdminOrThePayerButStillCapped() public {
        vm.deal(address(jackpot), 10 ether);
        vm.startPrank(hook);
        assertEq(jackpot.payout(hook), 0.3 ether, "payer naming itself is a normal capped payout");
        vm.stopPrank();
        assertEq(hook.balance, 0.3 ether);
        assertEq(jackpot.reserve(), 9.7 ether);
    }

    // ------------------------------------------------------------------ events and funding

    function test_setterEventsCarryPreviousValues() public {
        vm.startPrank(owner);
        vm.expectEmit(address(jackpot));
        emit HauntedVault.ReleaseBpsUpdated(300, 150);
        jackpot.setReleaseBps(150);
        vm.expectEmit(address(jackpot));
        emit HauntedVault.CooldownUpdated(10 minutes, 1 days);
        jackpot.setCooldown(1 days);
        vm.stopPrank();
    }

    function test_zeroValueFundingIsHarmless() public {
        vm.expectEmit(address(jackpot));
        emit HauntedVault.Funded(address(this), 0, 0);
        jackpot.fund{value: 0}();
        assertEq(jackpot.reserve(), 0);
    }

    function test_noFallbackForUnknownSelectors() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(jackpot).call{value: 1 ether}(hex"12345678");
        assertFalse(ok, "ETH with unknown calldata is refused");
        assertEq(jackpot.reserve(), 0);
    }

    function testFuzz_consecutiveReleasesEachWithinCap(uint256 reserve, uint8 count) public {
        reserve = bound(reserve, 1 ether, 1e24);
        count = uint8(bound(count, 1, 20));
        vm.prank(owner);
        jackpot.setCooldown(1);
        vm.deal(address(jackpot), reserve);
        uint256 remaining = reserve;
        for (uint256 i; i < count; ++i) {
            if (i != 0) vm.warp(block.timestamp + 1);
            uint256 before = jackpot.reserve();
            vm.prank(hook);
            uint256 paid = jackpot.payout(winner);
            assertLe(paid, before * 300 / 10_000, "every single release within 3% of the reserve before it");
            assertEq(paid, before * 300 / 10_000);
            remaining -= paid;
        }
        assertEq(jackpot.reserve(), remaining);
        assertEq(jackpot.totalReleased(), reserve - remaining);
        assertEq(winner.balance, reserve - remaining);
        assertEq(jackpot.releaseCount(), count);
    }
}
