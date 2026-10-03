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
| JackpotVault | `0x…` |
| CharityVault | `0x…` |
| HauntedHook | `0x…` (low 14 bits must be `0x10C0`) |
| HauntedHook CREATE2 salt | `0x…` |
| Launch pool (factory, PoolInitializationGuard) PoolKey | currency0 `0x0`, currency1 VOID, fee 3000, tickSpacing 60, hooks `0x…` |
| Haunted pool PoolKey | currency0 `0x0`, currency1 VOID, fee `0x800000`, tickSpacing `60`, hooks HauntedHook |
| Haunted pool PoolId | `0x…` |
| Uniswap v4 PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` (confirm against `network.json`) |
| Project owner (`$owner`) | `0x…` |
| Charity address | `0x…` |
| Launch transaction | `0x…` |
| Explorer links | |

## Constructor arguments as deployed

| Contract | Arguments |
|---|---|
| JackpotVault | admin = `$owner`, payoutBps = `300`, cooldownSeconds = `600` |
| CharityVault | admin = `$owner`, charity = `0x…`, donationBps = `100`, cooldownSeconds = `3600` |
| HauntedHook | poolManager = `0xE03A…3543`, voidToken = `$token`, initialOwner = `$owner`, jackpotVault = `$contract:JackpotVault`, charityVault = `$contract:CharityVault` |

## Post-deployment checklist (owner)

- [ ] `JackpotVault.grantRole(keccak256("PAYER_ROLE"), <HauntedHook>)`
- [ ] `CharityVault.grantRole(keccak256("SIGNALER_ROLE"), <HauntedHook>)`
- [ ] Fund JackpotVault and CharityVault with test ETH
- [ ] Fund the hoard: `VOID.approve(hook, n)` then `HauntedHook.fundHoard(n)`
- [ ] `PoolManager.initialize(hauntedPoolKey, sqrtPriceX96)`; confirm `PoolHaunted` and `hauntedPools() == 1`
- [ ] Add liquidity to the haunted pool
- [ ] Site configured with hook, vaults, token, haunted PoolKey; passes `abi.encode(user)` as hookData
- [ ] Optional: `forceOutcome` demonstrations, then `clearForcedOutcome`
