# Deployment record — Haunted Liquidity Pool (Sepolia, chain id 11155111)

To be completed by the network deployer after the ProjectFactory launch. Nothing below is filled
in by the contract stage, which holds no keys and broadcasts nothing.

## Build settings (must match for source verification)

| Setting | Value |
|---|---|
| solc | 0.8.26 |
| optimizer | enabled, 200 runs |
| evm_version | cancun |
| bytecode_hash | none |
| via_ir | false |
| remappings | `remappings.txt` |

## Addresses

| Item | Value |
|---|---|
| LaunchToken (VOID) | `0x…` |
| HauntedDeployment (manifest application) | `0x…` |
| JackpotVault (`bundle.jackpotVault()`) | `0x…` |
| CharityVault (`bundle.charityVault()`) | `0x…` |
| HauntedHook | `0x…` (low 14 bits must be `0x10C0`) |
| HauntedGame (`hook.game()`) | `0x…` |
| HauntedHook CREATE2 salt (`bundle.hookSalt()`) | `0x…` |
| Launch pool (factory, PoolInitializationGuard) PoolKey | currency0 `0x0`, currency1 VOID, fee 3000, tickSpacing 60, hooks `0x…` |
| Haunted pool PoolKey | currency0 `0x0`, currency1 VOID, fee `0x800000`, tickSpacing `60`, hooks HauntedHook |
| Haunted pool opening sqrtPriceX96 (enforced) | `79228162514264337593543950336` (1:1) |
| Haunted pool PoolId | `0x…` |
| Uniswap v4 PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` (confirm against `network.json`) |
| Project owner (`$owner`) | `0x…` |
| Charity address | `0x…` |
| Launch transaction | `0x…` |
| Explorer links | |

## Constructor arguments as deployed

The separate manifest step must replace the old vault/vault/hook application entries with one
`HauntedDeployment` entry. Do not add child contracts as additional application entries.

| Argument | Value |
|---|---|
| poolManager | Verified network PoolManager |
| token | `$token` |
| owner | `$owner` |
| charity | Approved charity recipient |
| jackpotBps | `300` |
| jackpotCooldown | `600` |
| charityBps | `100` |
| charityCooldown | `3600` |

All types are address or uint256 and the constructor is nonpayable. It deploys both vaults, mines
and deploys the hook, grants the hook its trigger roles and relinquishes its temporary vault roles.
The hook creates its game router. No constructor touches the token supply. The outer factory salt
needs no hook bits; the child hook salt is found on-chain against exact resolved arguments.

Simulate the full constructor at the intended factory address and outer salt, record the predicted
child addresses and gas estimate, and verify they match the final handoff. Mining has variable gas
cost and a 1,000,000-candidate bound. If the estimate exceeds the network transaction budget, select
another ordinary outer salt and simulate again. This is gas preflight, not external hook-salt mining.
Verify the source for the bundle and every child using the build settings above. Local tests check
all child runtime sizes and forbidden opcodes as well as the bundle runtime.

## Post-deployment checklist (operator)

- [ ] Confirm hook PAYER_ROLE/SIGNALER_ROLE, owner admin/pauser roles and no bundle admin/pauser roles.
- [ ] Confirm `hook.owner()`, `hook.game()` and vault references match the bundle handoff.
- [ ] Fund JackpotVault and CharityVault with expendable test ETH.
- [ ] Fund the hoard: `VOID.approve(hook, n)` then `HauntedHook.fundHoard(n)`.
- [ ] If absent, initialize the exact haunted key at `2^96`; check `hauntedPools() == 1`.
- [ ] Add haunted liquidity with explicit price limits; the factory's launch pool is separate.
- [ ] Configure the website with the exact PoolKey, vaults, hook and game address.
- [ ] Run a keeper for exact-block capture, execution, missed-draw expiry and fee delivery.
- [ ] Display game delay, fixed minOut, failure/missed-capture fees and claimable credits to players.
- [ ] Optional direct-swap `forceOutcome` demonstrations, then `clearForcedOutcome`.

Canonical initialization is permissionless only at the fixed key and 1:1 opening price. If someone
initialized it earlier, inspect the current price and liquidity before adding funds; initialization
is not an assurance that the market price has stayed at 1:1. The owner cannot choose another opening
price in this revision. Ordinary swaps pay the base LP fee; randomized trades use the commitment
protocol in [game.md](game.md). Default cooldowns are 600/3600 seconds; admins can lower either to
one second and can receive capped releases themselves. The frontend must describe that authority.
