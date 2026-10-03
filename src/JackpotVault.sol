// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HauntedVault} from "./HauntedVault.sol";

/// @title JackpotVault
/// @notice ETH reserve for the "mini jackpot" swap outcome. A payout is at most 3% of the reserve
/// (MAX_PAYOUT_BPS, immutable), at most once per cooldown, only while not paused, and only when
/// requested by a PAYER_ROLE holder (the HauntedHook once the admin grants it the role).
/// @dev No admin withdrawal exists. Funding is permissionless.
contract JackpotVault is HauntedVault {
    /// @notice Role allowed to trigger payouts. Intended holder: the HauntedHook.
    bytes32 public constant PAYER_ROLE = keccak256("PAYER_ROLE");

    /// @notice Hard cap of a single payout: 3% of the reserve.
    uint256 public constant MAX_PAYOUT_BPS = 300;

    event JackpotPaid(address indexed winner, uint256 amount, uint256 reserveBefore);

    /// @param admin Project owner: DEFAULT_ADMIN_ROLE and PAUSER_ROLE.
    /// @param payoutBps Opening payout share in basis points, in (0, 300].
    /// @param cooldownSeconds Minimum seconds between two payouts, at most 30 days.
    constructor(address admin, uint256 payoutBps, uint256 cooldownSeconds)
        HauntedVault(admin, MAX_PAYOUT_BPS, payoutBps, cooldownSeconds)
    {}

    /// @notice Pays the capped jackpot share to `winner`. Reverts when paused, on cooldown or empty.
    /// @return amount The ETH paid.
    function payout(address winner) external onlyRole(PAYER_ROLE) returns (uint256 amount) {
        uint256 reserveBefore = reserve();
        amount = _release(winner);
        emit JackpotPaid(winner, amount, reserveBefore);
    }
}
