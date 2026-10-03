// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title HauntedVault
/// @notice Shared base of the JackpotVault and the CharityVault: an ETH reserve that releases at
/// most a capped share of itself per trigger, never more often than one cooldown apart, only while
/// not paused, and only to the caller holding the trigger role.
/// @dev There is no administrative withdrawal: ETH leaves a vault only through `_release`, which
/// is bounded by `MAX_RELEASE_BPS` of the reserve at the moment of the call. Funding is permissionless
/// (plain transfers or `fund()`).
abstract contract HauntedVault is AccessControl, Pausable, ReentrancyGuard {
    /// @notice Role that may pause and unpause releases. Held by the admin at deployment.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice Longest cooldown the admin may configure.
    uint256 public constant MAX_COOLDOWN = 30 days;

    /// @notice Hard upper bound of a single release, in basis points of the reserve. Immutable per vault.
    uint256 public immutable MAX_RELEASE_BPS;

    /// @notice Current release share in basis points of the reserve; `0 < releaseBps <= MAX_RELEASE_BPS`.
    uint256 public releaseBps;

    /// @notice Minimum seconds between two releases.
    uint256 public cooldown;

    /// @notice Timestamp of the last release (0 before the first one).
    uint256 public lastReleaseAt;

    /// @notice Total ETH ever released by this vault.
    uint256 public totalReleased;

    /// @notice Number of releases performed.
    uint256 public releaseCount;

    event Funded(address indexed from, uint256 amount, uint256 reserve);
    event Released(address indexed to, uint256 amount, uint256 reserveBefore, uint256 releaseIndex);
    event ReleaseBpsUpdated(uint256 previousBps, uint256 newBps);
    event CooldownUpdated(uint256 previousCooldown, uint256 newCooldown);

    error ZeroAddress();
    error InvalidReleaseBps(uint256 bps, uint256 max);
    error InvalidCooldown(uint256 cooldown, uint256 max);
    error CooldownActive(uint256 availableAt);
    error NothingToRelease();
    error TransferFailed(address to, uint256 amount);

    /// @param admin Holder of DEFAULT_ADMIN_ROLE and PAUSER_ROLE. The launch passes the project owner.
    /// @param maxReleaseBps Hard cap of one release, fixed for the vault's life (300 for the jackpot, 100 for charity).
    /// @param initialReleaseBps Opening release share; must be in (0, maxReleaseBps].
    /// @param initialCooldown Opening cooldown in seconds; must be at most MAX_COOLDOWN.
    constructor(address admin, uint256 maxReleaseBps, uint256 initialReleaseBps, uint256 initialCooldown) {
        if (admin == address(0)) revert ZeroAddress();
        if (maxReleaseBps == 0 || maxReleaseBps > BPS) revert InvalidReleaseBps(maxReleaseBps, BPS);
        MAX_RELEASE_BPS = maxReleaseBps;
        _setReleaseBps(initialReleaseBps);
        _setCooldown(initialCooldown);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /// @notice Permissionless funding.
    receive() external payable {
        emit Funded(msg.sender, msg.value, address(this).balance);
    }

    /// @notice Permissionless funding with an explicit function, for wallets that cannot send to `receive`.
    function fund() external payable {
        emit Funded(msg.sender, msg.value, address(this).balance);
    }

    /// @notice The ETH currently held, which every cap is measured against.
    function reserve() public view returns (uint256) {
        return address(this).balance;
    }

    /// @notice The amount the next release would pay at the current reserve (ignores cooldown and pause).
    function nextReleaseAmount() public view returns (uint256) {
        return reserve() * releaseBps / BPS;
    }

    /// @notice True when a release is allowed right now: not paused, cooldown elapsed, reserve nonzero.
    function canRelease() public view returns (bool) {
        return !paused() && block.timestamp >= releaseAvailableAt() && nextReleaseAmount() > 0;
    }

    /// @notice The earliest timestamp of the next release.
    function releaseAvailableAt() public view returns (uint256) {
        return lastReleaseAt == 0 ? 0 : lastReleaseAt + cooldown;
    }

    /// @notice Admin control: change the release share, never above the immutable cap.
    function setReleaseBps(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setReleaseBps(newBps);
    }

    /// @notice Admin control: change the cooldown, never above MAX_COOLDOWN.
    function setCooldown(uint256 newCooldown) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setCooldown(newCooldown);
    }

    /// @notice Pause releases. Funding stays open.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume releases.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @dev Releases `releaseBps` of the reserve to `to`. Reverts (rather than silently paying zero)
    /// when paused, within the cooldown, or when the reserve is too small, so that callers can tell
    /// a skipped release from a paid one.
    function _release(address to) internal nonReentrant whenNotPaused returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        uint256 availableAt = releaseAvailableAt();
        if (block.timestamp < availableAt) revert CooldownActive(availableAt);
        uint256 reserveBefore = reserve();
        amount = reserveBefore * releaseBps / BPS;
        if (amount == 0) revert NothingToRelease();

        lastReleaseAt = block.timestamp;
        totalReleased += amount;
        uint256 index = ++releaseCount;

        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed(to, amount);
        emit Released(to, amount, reserveBefore, index);
    }

    function _setReleaseBps(uint256 newBps) private {
        if (newBps == 0 || newBps > MAX_RELEASE_BPS) revert InvalidReleaseBps(newBps, MAX_RELEASE_BPS);
        emit ReleaseBpsUpdated(releaseBps, newBps);
        releaseBps = newBps;
    }

    function _setCooldown(uint256 newCooldown) private {
        if (newCooldown > MAX_COOLDOWN) revert InvalidCooldown(newCooldown, MAX_COOLDOWN);
        emit CooldownUpdated(cooldown, newCooldown);
        cooldown = newCooldown;
    }
}
