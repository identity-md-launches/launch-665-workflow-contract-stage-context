// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HauntedHook} from "./HauntedHook.sol";
import {HauntedVault} from "./HauntedVault.sol";
import {JackpotVault} from "./JackpotVault.sol";
import {CharityVault} from "./CharityVault.sol";
import {HookSaltMiner} from "./HookSaltMiner.sol";

/// @notice Constructor-only launch bundle. Mines the child hook salt and completes both vault role
/// grants atomically. The outer ProjectFactory salt needs no special bits or service-side mining.
/// @dev Has no methods that can exercise administrative authority. It relinquishes all vault roles
/// before construction completes. The launch token is supplied; none of its supply is moved here.
contract HauntedDeployment {
    JackpotVault public immutable jackpotVault;
    CharityVault public immutable charityVault;
    HauntedHook public immutable hook;
    bytes32 public immutable hookSalt;

    constructor(
        address poolManager,
        address token,
        address owner,
        address charity,
        uint256 jackpotBps,
        uint256 jackpotCooldown,
        uint256 charityBps,
        uint256 charityCooldown
    ) {
        jackpotVault = new JackpotVault(address(this), jackpotBps, jackpotCooldown);
        charityVault = new CharityVault(address(this), charity, charityBps, charityCooldown);
        bytes memory initCode = abi.encodePacked(
            type(HauntedHook).creationCode,
            abi.encode(poolManager, token, owner, address(jackpotVault), address(charityVault))
        );
        (bytes32 salt,) =
            HookSaltMiner.mine(address(this), keccak256(initCode), HookSaltMiner.HAUNTED_HOOK_FLAGS, 0, 1_000_000);
        hookSalt = salt;
        hook = new HauntedHook{salt: salt}(poolManager, token, owner, address(jackpotVault), address(charityVault));
        jackpotVault.grantRole(jackpotVault.PAYER_ROLE(), address(hook));
        charityVault.grantRole(charityVault.SIGNALER_ROLE(), address(hook));
        _handoff(jackpotVault, owner);
        _handoff(charityVault, owner);
    }

    function _handoff(HauntedVault vault, address owner) private {
        bytes32 admin = vault.DEFAULT_ADMIN_ROLE();
        bytes32 pauser = vault.PAUSER_ROLE();
        vault.grantRole(admin, owner);
        vault.grantRole(pauser, owner);
        vault.renounceRole(pauser, address(this));
        vault.renounceRole(admin, address(this));
    }
}
