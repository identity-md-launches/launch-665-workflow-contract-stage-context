// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HauntedVault} from "./HauntedVault.sol";

/// @title CharityVault
/// @notice ETH reserve for the "charity signal" swap outcome. A donation is at most 1% of the
/// reserve (MAX_DONATION_BPS, immutable), at most once per cooldown, only while not paused, only
/// to the configured charity address, and only when requested by a SIGNALER_ROLE holder (the
/// HauntedHook once the admin grants it the role).
/// @dev No admin withdrawal exists. The admin may re-point the charity address (event emitted).
contract CharityVault is HauntedVault {
    /// @notice Role allowed to trigger donations. Intended holder: the HauntedHook.
    bytes32 public constant SIGNALER_ROLE = keccak256("SIGNALER_ROLE");

    /// @notice Hard cap of a single donation: 1% of the reserve.
    uint256 public constant MAX_DONATION_BPS = 100;

    /// @notice Recipient of every donation.
    address public charity;

    event CharityUpdated(address indexed previousCharity, address indexed newCharity);
    event Donated(address indexed charity, uint256 amount, uint256 reserveBefore);

    /// @param admin Project owner: DEFAULT_ADMIN_ROLE and PAUSER_ROLE.
    /// @param charity_ Donation recipient; nonzero.
    /// @param donationBps Opening donation share in basis points, in (0, 100].
    /// @param cooldownSeconds Minimum seconds between two donations, at most 30 days.
    constructor(address admin, address charity_, uint256 donationBps, uint256 cooldownSeconds)
        HauntedVault(admin, MAX_DONATION_BPS, donationBps, cooldownSeconds)
    {
        _setCharity(charity_);
    }

    /// @notice Admin control: change the donation recipient.
    function setCharity(address newCharity) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setCharity(newCharity);
    }

    /// @notice Sends the capped donation share to the charity. Reverts when paused, on cooldown or empty.
    /// @return amount The ETH donated.
    function donate() external onlyRole(SIGNALER_ROLE) returns (uint256 amount) {
        uint256 reserveBefore = reserve();
        address to = charity;
        amount = _release(to);
        emit Donated(to, amount, reserveBefore);
    }

    function _setCharity(address newCharity) private {
        if (newCharity == address(0)) revert ZeroAddress();
        emit CharityUpdated(charity, newCharity);
        charity = newCharity;
    }
}
