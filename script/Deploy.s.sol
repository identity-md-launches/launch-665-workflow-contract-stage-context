// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {JackpotVault} from "../src/JackpotVault.sol";
import {CharityVault} from "../src/CharityVault.sol";
import {HauntedHook} from "../src/HauntedHook.sol";
import {HookSaltMiner} from "../src/HookSaltMiner.sol";
import {HauntedDeployment} from "../src/HauntedDeployment.sol";

/// @title Deploy
/// @notice Standalone deployment of the Haunted Liquidity Pool contracts for a local chain or for an
/// operator-run Sepolia test deployment. The production launch goes through the network's
/// ProjectFactory, which deploys `LaunchToken` and `HauntedDeployment`. The bundle mines its child
/// hook salt and grants its roles in the constructor; this script is not used by that service.
/// @dev `run()` reads only EXPECTED_CHAIN_ID, POOL_MANAGER, PROJECT_OWNER and CHARITY (plus optional
/// cap/cooldown overrides) from the environment and refuses every chain except Anvil (31337) and
/// Sepolia (11155111). It never reads a key: the broadcaster is whatever the operator passes to forge.
/// Tests call `deploy` directly with an explicit config and never read the environment.
contract Deploy is Script {
    struct Config {
        /// The chain's Uniswap v4 PoolManager.
        address poolManager;
        /// Project owner: hook owner, vault admin and pauser.
        address owner;
        /// Charity donation recipient.
        address charity;
        /// Jackpot payout share in bps (<= 300) and cooldown in seconds.
        uint256 jackpotBps;
        uint256 jackpotCooldown;
        /// Charity donation share in bps (<= 100) and cooldown in seconds.
        uint256 charityBps;
        uint256 charityCooldown;
    }

    struct Deployment {
        LaunchToken token;
        JackpotVault jackpotVault;
        CharityVault charityVault;
        HauntedHook hook;
        bytes32 hookSalt;
        HauntedDeployment bundle;
    }

    uint256 public constant ANVIL_CHAIN_ID = 31337;
    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;

    uint256 public constant DEFAULT_JACKPOT_BPS = 300; // 3%, the cap
    uint256 public constant DEFAULT_JACKPOT_COOLDOWN = 10 minutes;
    uint256 public constant DEFAULT_CHARITY_BPS = 100; // 1%, the cap
    uint256 public constant DEFAULT_CHARITY_COOLDOWN = 1 hours;
    uint256 public constant MAX_SALT_ATTEMPTS = 1_000_000;

    error UnexpectedChainId(uint256 expected, uint256 actual);
    error UnsupportedChainId(uint256 chainId);

    /// @dev Reads the configuration from the environment and broadcasts one batch of deployments.
    function run() external returns (Deployment memory d) {
        uint256 expected = vm.envUint("EXPECTED_CHAIN_ID");
        if (expected != ANVIL_CHAIN_ID && expected != SEPOLIA_CHAIN_ID) revert UnsupportedChainId(expected);
        if (expected != block.chainid) revert UnexpectedChainId(expected, block.chainid);

        Config memory config = Config({
            poolManager: vm.envAddress("POOL_MANAGER"),
            owner: vm.envAddress("PROJECT_OWNER"),
            charity: vm.envAddress("CHARITY"),
            jackpotBps: vm.envOr("JACKPOT_BPS", DEFAULT_JACKPOT_BPS),
            jackpotCooldown: vm.envOr("JACKPOT_COOLDOWN", DEFAULT_JACKPOT_COOLDOWN),
            charityBps: vm.envOr("CHARITY_BPS", DEFAULT_CHARITY_BPS),
            charityCooldown: vm.envOr("CHARITY_COOLDOWN", DEFAULT_CHARITY_COOLDOWN)
        });

        vm.startBroadcast();
        d = deploy(config);
        vm.stopBroadcast();
    }

    /// @notice Deploys the token and a fully wired constructor bundle. All salts used for child
    /// hooks are mined by that bundle against its own address, including when run under broadcast.
    function deploy(Config memory config) public returns (Deployment memory d) {
        d.token = new LaunchToken();
        d.bundle = new HauntedDeployment(
            config.poolManager,
            address(d.token),
            config.owner,
            config.charity,
            config.jackpotBps,
            config.jackpotCooldown,
            config.charityBps,
            config.charityCooldown
        );
        d.jackpotVault = d.bundle.jackpotVault();
        d.charityVault = d.bundle.charityVault();
        d.hook = d.bundle.hook();
        d.hookSalt = d.bundle.hookSalt();
    }

    /// @notice The exact creation code the factory (or anyone) must hash to mine the hook salt.
    function hookInitCode(address poolManager, address token, address owner, address jackpotVault, address charityVault)
        public
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(HauntedHook).creationCode, abi.encode(poolManager, token, owner, jackpotVault, charityVault)
        );
    }

    /// @notice Mines the launch salt for a given CREATE2 deployer and constructor arguments, without deploying.
    function mineHookSalt(
        address create2Deployer,
        address poolManager,
        address token,
        address owner,
        address jackpotVault,
        address charityVault
    ) external pure returns (bytes32 salt, address predicted) {
        bytes32 initCodeHash = keccak256(hookInitCode(poolManager, token, owner, jackpotVault, charityVault));
        uint160 flags = HookSaltMiner.HAUNTED_HOOK_FLAGS;
        return HookSaltMiner.mine(create2Deployer, initCodeHash, flags, 0, MAX_SALT_ATTEMPTS);
    }
}
