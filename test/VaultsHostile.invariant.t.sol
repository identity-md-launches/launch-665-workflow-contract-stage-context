// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JackpotVault} from "../src/JackpotVault.sol";
import {CharityVault} from "../src/CharityVault.sol";
import {HauntedVault} from "../src/HauntedVault.sol";

/// @dev A recipient that refuses ETH.
contract Refuser {
    receive() external payable {
        revert("refused");
    }
}

/// @dev Drives both vaults at once with hostile recipients, role churn, charity re-pointing, pauses,
/// config changes and time. Every release attempt is checked against `canRelease()` before the call
/// and against a "no trace on failure" rule after it. Jackpot recipients include plain EOAs, a
/// refuser, zero and the vault itself; invalid recipients must leave reserves and accounting intact.
contract HostileVaultHandler is Test {
    JackpotVault public jackpot;
    CharityVault public charity;
    address public admin;

    address[] public jackpotWinners;
    address[] public charities;
    Refuser public refuser;

    uint256 public jackpotFunded;
    uint256 public charityFunded;
    uint256 public jackpotReleases;
    uint256 public charityReleases;

    bool public payerHasRole = true;
    bool public signalerHasRole = true;

    bool public oracleViolated;
    bool public capViolated;
    bool public traceOnFailure;
    bool public recipientMismatch;

    constructor(JackpotVault j, CharityVault c, address admin_) {
        jackpot = j;
        charity = c;
        admin = admin_;
        refuser = new Refuser();
        for (uint256 i; i < 3; ++i) {
            jackpotWinners.push(makeAddr(string.concat("jackpotWinner", vm.toString(i))));
            charities.push(makeAddr(string.concat("charity", vm.toString(i))));
        }
        jackpotWinners.push(address(refuser));
        jackpotWinners.push(address(0));
        jackpotWinners.push(address(jackpot));
        charities.push(address(refuser));
    }

    receive() external payable {}

    // ------------------------------------------------------------------ funding and time

    function fundJackpot(uint256 amount) external {
        amount = bound(amount, 0, 500 ether);
        vm.deal(address(this), amount);
        jackpot.fund{value: amount}();
        jackpotFunded += amount;
    }

    function fundCharity(uint256 amount) external {
        amount = bound(amount, 0, 500 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(charity).call{value: amount}("");
        require(ok, "fund failed");
        charityFunded += amount;
    }

    function warp(uint256 by) external {
        by = bound(by, 0, 2 days);
        vm.warp(block.timestamp + by);
    }

    // ------------------------------------------------------------------ releases

    function payJackpot(uint256 winnerSeed) external {
        address winner = jackpotWinners[winnerSeed % jackpotWinners.length];
        bool predicted = jackpot.canRelease() && payerHasRole && winner != address(refuser) && winner != address(0)
            && winner != address(jackpot);
        uint256 reserveBefore = jackpot.reserve();
        uint256 releasedBefore = jackpot.totalReleased();
        uint256 countBefore = jackpot.releaseCount();
        uint256 lastBefore = jackpot.lastReleaseAt();
        uint256 winnerBefore = winner.balance;

        (bool ok, bytes memory ret) = address(jackpot).call(abi.encodeCall(jackpot.payout, (winner)));
        if (ok != predicted) oracleViolated = true;
        if (!ok) {
            if (
                jackpot.reserve() != reserveBefore || jackpot.totalReleased() != releasedBefore
                    || jackpot.releaseCount() != countBefore || jackpot.lastReleaseAt() != lastBefore
            ) traceOnFailure = true;
            return;
        }
        uint256 paid = abi.decode(ret, (uint256));
        jackpotReleases++;
        if (paid > reserveBefore * 300 / 10_000 || paid != reserveBefore * jackpot.releaseBps() / 10_000) {
            capViolated = true;
        }
        if (winner.balance != winnerBefore + paid) recipientMismatch = true;
        if (jackpot.reserve() != reserveBefore - paid) recipientMismatch = true;
    }

    function donate() external {
        address to = charity.charity();
        bool predicted = charity.canRelease() && signalerHasRole && to != address(refuser);
        uint256 reserveBefore = charity.reserve();
        uint256 releasedBefore = charity.totalReleased();
        uint256 countBefore = charity.releaseCount();
        uint256 lastBefore = charity.lastReleaseAt();
        uint256 toBefore = to.balance;

        (bool ok, bytes memory ret) = address(charity).call(abi.encodeCall(charity.donate, ()));
        if (ok != predicted) oracleViolated = true;
        if (!ok) {
            if (
                charity.reserve() != reserveBefore || charity.totalReleased() != releasedBefore
                    || charity.releaseCount() != countBefore || charity.lastReleaseAt() != lastBefore
            ) traceOnFailure = true;
            return;
        }
        uint256 paid = abi.decode(ret, (uint256));
        charityReleases++;
        if (paid > reserveBefore * 100 / 10_000 || paid != reserveBefore * charity.releaseBps() / 10_000) {
            capViolated = true;
        }
        if (to.balance != toBefore + paid) recipientMismatch = true;
    }

    // ------------------------------------------------------------------ admin churn

    function setCharity(uint256 seed) external {
        vm.prank(admin);
        charity.setCharity(charities[seed % charities.length]);
    }

    function togglePayerRole() external {
        bytes32 role = jackpot.PAYER_ROLE();
        vm.prank(admin);
        if (payerHasRole) jackpot.revokeRole(role, address(this));
        else jackpot.grantRole(role, address(this));
        payerHasRole = !payerHasRole;
    }

    function toggleSignalerRole() external {
        bytes32 role = charity.SIGNALER_ROLE();
        vm.prank(admin);
        if (signalerHasRole) charity.revokeRole(role, address(this));
        else charity.grantRole(role, address(this));
        signalerHasRole = !signalerHasRole;
    }

    function setJackpotPaused(bool p) external {
        if (p == jackpot.paused()) return;
        vm.prank(admin);
        if (p) jackpot.pause();
        else jackpot.unpause();
    }

    function setCharityPaused(bool p) external {
        if (p == charity.paused()) return;
        vm.prank(admin);
        if (p) charity.pause();
        else charity.unpause();
    }

    function setJackpotConfig(uint256 bps, uint256 cooldown) external {
        bps = bound(bps, 1, 300);
        cooldown = bound(cooldown, 1, 30 days);
        vm.startPrank(admin);
        jackpot.setReleaseBps(bps);
        jackpot.setCooldown(cooldown);
        vm.stopPrank();
    }

    function setCharityConfig(uint256 bps, uint256 cooldown) external {
        bps = bound(bps, 1, 100);
        cooldown = bound(cooldown, 1, 30 days);
        vm.startPrank(admin);
        charity.setReleaseBps(bps);
        charity.setCooldown(cooldown);
        vm.stopPrank();
    }

    /// @dev Out-of-range admin inputs must be refused and leave the config untouched.
    function rejectBadConfig(uint256 bps, uint256 cooldown) external {
        bps = bound(bps, 301, type(uint128).max);
        cooldown = bound(cooldown, 30 days + 1, type(uint128).max);
        uint256 bpsBefore = jackpot.releaseBps();
        uint256 cooldownBefore = jackpot.cooldown();
        vm.startPrank(admin);
        (bool ok1,) = address(jackpot).call(abi.encodeCall(jackpot.setReleaseBps, (bps)));
        (bool ok2,) = address(jackpot).call(abi.encodeCall(jackpot.setCooldown, (cooldown)));
        (bool ok3,) = address(jackpot).call(abi.encodeCall(jackpot.setReleaseBps, (0)));
        (bool ok4,) = address(charity).call(abi.encodeCall(charity.setCharity, (address(0))));
        vm.stopPrank();
        require(!ok1 && !ok2 && !ok3 && !ok4, "bad config accepted");
        require(jackpot.releaseBps() == bpsBefore && jackpot.cooldown() == cooldownBefore, "config changed");
    }

    /// @dev Former bypasses remain invalid throughout role, pause and payout sequences.
    function rejectZeroCooldownAndSelfCharity() external {
        uint256 jackpotCooldown = jackpot.cooldown();
        uint256 charityCooldown = charity.cooldown();
        address recipient = charity.charity();
        bytes memory reason = abi.encodeWithSelector(HauntedVault.InvalidCooldown.selector, 0, 30 days);
        vm.startPrank(admin);
        vm.expectRevert(reason);
        jackpot.setCooldown(0);
        vm.expectRevert(reason);
        charity.setCooldown(0);
        vm.expectRevert(HauntedVault.SelfRecipient.selector);
        charity.setCharity(address(charity));
        vm.stopPrank();
        assertEq(jackpot.cooldown(), jackpotCooldown);
        assertEq(charity.cooldown(), charityCooldown);
        assertEq(charity.charity(), recipient);
    }

    /// @dev Strangers never get anywhere.
    function strangerAttempts(uint256 seed) external {
        address stranger = makeAddr(string.concat("stranger", vm.toString(seed % 5)));
        vm.startPrank(stranger);
        (bool a,) = address(jackpot).call(abi.encodeCall(jackpot.payout, (stranger)));
        (bool b,) = address(charity).call(abi.encodeCall(charity.donate, ()));
        (bool c,) = address(jackpot).call(abi.encodeCall(jackpot.pause, ()));
        (bool d,) = address(jackpot).call(abi.encodeCall(jackpot.setCooldown, (0)));
        (bool e,) = address(charity).call(abi.encodeCall(charity.setCharity, (stranger)));
        (bool f,) = address(jackpot).call(abi.encodeCall(jackpot.grantRole, (jackpot.PAYER_ROLE(), stranger)));
        vm.stopPrank();
        require(!a && !b && !c && !d && !e && !f, "stranger succeeded");
    }

    // ------------------------------------------------------------------ ghosts

    function jackpotWinnerBalances() external view returns (uint256 total) {
        for (uint256 i; i < jackpotWinners.length; ++i) {
            // The vault is an invalid payout target, not an external recipient of released funds.
            if (jackpotWinners[i] == address(jackpot)) continue;
            total += jackpotWinners[i].balance;
        }
    }

    function charityBalances() external view returns (uint256 total) {
        for (uint256 i; i < charities.length; ++i) {
            total += charities[i].balance;
        }
    }
}

/// @notice Both vaults under random sequences that include hostile recipients and role churn.
contract VaultsHostileInvariantTest is Test {
    JackpotVault internal jackpot;
    CharityVault internal charity;
    HostileVaultHandler internal handler;
    address internal admin = makeAddr("admin");

    function setUp() public {
        vm.warp(1_000_000);
        jackpot = new JackpotVault(admin, 300, 10 minutes);
        charity = new CharityVault(admin, makeAddr("charity0"), 100, 1 hours);
        handler = new HostileVaultHandler(jackpot, charity, admin);
        bytes32 payer = jackpot.PAYER_ROLE();
        bytes32 signaler = charity.SIGNALER_ROLE();
        vm.startPrank(admin);
        jackpot.grantRole(payer, address(handler));
        charity.grantRole(signaler, address(handler));
        vm.stopPrank();
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_fundsConservedInBothVaults() public view {
        assertEq(jackpot.reserve() + jackpot.totalReleased(), handler.jackpotFunded());
        assertEq(charity.reserve() + charity.totalReleased(), handler.charityFunded());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_everyReleasedWeiReachedAnAcceptingRecipient() public view {
        // The charities list and the winners list share the refuser, which never holds anything.
        assertEq(address(handler.refuser()).balance, 0, "the refuser never received ETH");
        assertEq(handler.jackpotWinnerBalances(), jackpot.totalReleased());
        assertEq(handler.charityBalances(), charity.totalReleased());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_releaseRulesAndOracle() public view {
        assertFalse(handler.oracleViolated(), "canRelease predicted the wrong result");
        assertFalse(handler.capViolated(), "a release exceeded its cap or share");
        assertFalse(handler.traceOnFailure(), "a failed release changed state");
        assertFalse(handler.recipientMismatch(), "paid amount did not reach the recipient");
        assertEq(jackpot.releaseCount(), handler.jackpotReleases());
        assertEq(charity.releaseCount(), handler.charityReleases());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_configAlwaysWithinImmutableBounds() public view {
        assertGt(jackpot.releaseBps(), 0);
        assertLe(jackpot.releaseBps(), 300);
        assertGt(charity.releaseBps(), 0);
        assertLe(charity.releaseBps(), 100);
        assertGe(jackpot.cooldown(), 1);
        assertGe(charity.cooldown(), 1);
        assertLe(jackpot.cooldown(), 30 days);
        assertLe(charity.cooldown(), 30 days);
        assertTrue(charity.charity() != address(0));
        assertTrue(charity.charity() != address(charity));
        assertEq(jackpot.hasRole(jackpot.PAYER_ROLE(), address(handler)), handler.payerHasRole());
        assertEq(charity.hasRole(charity.SIGNALER_ROLE(), address(handler)), handler.signalerHasRole());
    }
}
