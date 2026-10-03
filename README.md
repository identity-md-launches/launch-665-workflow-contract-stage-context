# Haunted Liquidity Pool — contracts

**Experimental Sepolia testnet software.** Nothing here is audited; the game is a toy and the ETH
in its vaults is test ETH. See "Trust assumptions and known limitations" before relying on any of it.

This repository holds the contract stage of the launch: the fixed-supply launch token, a Uniswap v4
hook that turns every swap into a visible outcome, two capped ETH vaults, a deploy script for local
and operator use, Foundry tests (unit, fuzz, invariant) and ABI exports. The website, IPFS
publication, Sepolia deployment and verification are later stages of the workflow and are not here.

## Contracts

| Contract | File | Role |
|---|---|---|
| `LaunchToken` | `src/LaunchToken.sol` | Haunted VOID (`VOID`), fixed supply 1,000,000,000 × 10^18, minted to the deployer |
| `JackpotVault` | `src/JackpotVault.sol` | ETH reserve; pays ≤ 3% of itself per jackpot, once per cooldown |
| `CharityVault` | `src/CharityVault.sol` | ETH reserve; donates ≤ 1% of itself per signal, once per cooldown, to the charity address |
| `HauntedVault` | `src/HauntedVault.sol` | Shared base of the two vaults (roles, pause, reentrancy guard, caps, cooldowns) |
| `HauntedHook` | `src/HauntedHook.sol` | Uniswap v4 hook: afterInitialize, beforeSwap, afterSwap; resolves each swap into one of eight outcomes |
| `HookSaltMiner` | `src/HookSaltMiner.sol` | Pure CREATE2 salt mining for the hook's permission bits (used by script and tests) |

ABIs: `docs/abi/LaunchToken.json`, `docs/abi/HauntedHook.json`, `docs/abi/JackpotVault.json`,
`docs/abi/CharityVault.json`.

### LaunchToken (Haunted VOID, VOID)

Plain OpenZeppelin ERC-20. No constructor arguments, 18 decimals, exactly 10^27 minor units minted
once to `msg.sender` (the ProjectFactory at launch). No mint, burn, owner, pause, blocklist, fee or
upgrade function; no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in the runtime. The brief asked
for exactly this ("plain ERC-20 transfers, no transfer taxes, hidden minting or privileged
withdrawals"), so nothing requested was left out of the token.

The game "burns" VOID by transferring it to `0x000000000000000000000000000000000000dEaD`. Total
supply therefore never changes; `HauntedHook.totalBurned()` and the dead address balance are the
burn counters the site should show.

### HauntedHook

A dynamic-fee ETH/VOID pool whose `hooks` field is this contract is *haunted*. The hook:

* **afterInitialize** — admits the pool only if `currency0` is native ETH, `currency1` is VOID and
  the fee is the dynamic-fee flag (`0x800000`); anything else reverts and the pool is not created.
  It then sets the pool's stored LP fee to 0.30% and emits `PoolHaunted`. Several haunted pools
  (different tick spacings) may exist; they share one game state.
* **beforeSwap** — draws the outcome for this swap, stores it as pending and returns the LP fee
  override for the swap.
* **afterSwap** — applies the outcome's side effect, emits the outcome event and `SwapResolved`,
  then clears the pending state.

Outcomes and the draw (`roll` in `[0, 1000)`, `corruption` in `[0, 100]`):

| Roll band | Outcome | LP fee on the swap | Side effect | Event |
|---|---|---|---|---|
| `< 5 + corruption/10` | `RealityCollapse` | 5% | corruption → 0, `collapseCount++` | `RealityCollapse` |
| `< 600` | `NormalTrade` | 0.30% | corruption +1 | `NormalTrade` |
| `< 700` | `FreeSwap` | 0% | corruption +1 | `FreeSwap` |
| `< 800` | `CorruptedFee` | 0.30% + 0.05% × corruption, capped at 5% | corruption +5 | `CorruptedFee` |
| `< 880` | `VoidBurn` | 0.30% | burns VOID from the hoard, corruption +1 | `VoidBurned` / `BurnSkipped` |
| `< 940` | `LoreSignal` | 0.30% | unlocks lore fragment `loreSignals % 13`, corruption +1 | `LoreSignal` |
| `< 970` | `MiniJackpot` | 0.30% | `JackpotVault.payout(swapper)`, corruption +1 | `MiniJackpot` / `JackpotSkipped` |
| otherwise | `CharitySignal` | 0.30% | `CharityVault.donate()`, corruption +1 | `CharitySignal` / `CharitySkipped` |

Corruption is capped at 100, so the corrupted fee reaches its 5% ceiling at level 94. Every swap
also emits `SwapResolved(poolId, swapper, outcome, fee, roll, forced, corruption, swapIndex)`.

*Burn limits.* A burn is `burnBps` (default 1%, owner-settable up to 5%) of the VOID moved by the
swap, never more than 1% of the hoard per event. The hoard is VOID held by the hook, funded by
anyone (`fundHoard(amount)` after an approval, or a plain transfer). The hook can send VOID only to
the dead address; there is no withdrawal. An empty hoard or `burnBps = 0` yields `BurnSkipped`.

*Vault calls never block a swap.* Jackpot and charity calls are wrapped in `try/catch`; a paused,
empty, cooling-down or role-less vault, or a winner that rejects ETH, produces a `…Skipped` event
with the vault's revert data and the swap completes.

*Who is the swapper?* Hooks see the router, not the user. If `hookData` is a single abi-encoded
nonzero address, that address is the beneficiary (jackpot recipient and event subject); otherwise
the router `sender` is used. The frontend must pass `abi.encode(userAddress)` as `hookData` or
jackpots go to the router, where they are refused or stranded. The test router cannot receive
ETH, so a jackpot aimed at it is recorded as skipped and the cooldown is not consumed.

*Owner test controls (Sepolia).* `forceOutcome(outcome)` makes every swap resolve to that outcome
until `clearForcedOutcome()`; `forceCorruption(0..100)` sets the level; `setBurnBps(0..500)`.
Ownership is two-step (`Ownable2Step`). Nothing else is privileged; in particular the owner cannot
pause swaps, move the hoard or change the vault addresses.

*Reentrancy.* The pending flag stays set from `beforeSwap` through the end of `afterSwap`. A
payout recipient that re-enters the PoolManager and swaps on a haunted pool is refused by
`beforeSwap` (`SwapAlreadyPending`), which makes its receive revert, which makes the vault revert,
which the hook records as `JackpotSkipped` with nothing paid. Tested in
`test_nestedSwapDuringPayoutIsRejected`.

### JackpotVault and CharityVault

Both extend `HauntedVault`: OpenZeppelin `AccessControl`, `Pausable`, `ReentrancyGuard`.

* Roles: `DEFAULT_ADMIN_ROLE` and `PAUSER_ROLE` go to the admin passed to the constructor (the
  project owner). The trigger role (`PAYER_ROLE` on the jackpot, `SIGNALER_ROLE` on the charity
  vault) must be **granted by the admin to the hook after deployment** (see "Operational steps").
* Caps: a release is `releaseBps` of the reserve at call time, `0 < releaseBps ≤ MAX_RELEASE_BPS`;
  the maximum is an immutable set per vault — **300 bps (3%) for jackpots, 100 bps (1%) for
  donations** — and the admin can only lower the share below it, never raise it above.
* Cooldowns: `block.timestamp ≥ lastReleaseAt + cooldown`, cooldown ≤ 30 days, admin-settable.
* Pause: `PAUSER_ROLE` pauses releases; funding stays open.
* Funding: permissionless, `receive()` or `fund()`.
* No withdrawal of any kind by anyone: ETH leaves only through the capped release. On a testnet
  this means unused reserves stay in the vault forever; that is the intended trust posture.
* `CharityVault.setCharity` lets the admin re-point donations (nonzero only, event emitted).

### Deploy script

`script/Deploy.s.sol` is for a local chain or an operator-run Sepolia test deployment; the
production launch goes through the network's ProjectFactory and does not use it. `run()` reads
`EXPECTED_CHAIN_ID` (must equal the connected chain and be 31337 or 11155111), `POOL_MANAGER`,
`PROJECT_OWNER`, `CHARITY` and optional `JACKPOT_BPS`, `JACKPOT_COOLDOWN`, `CHARITY_BPS`,
`CHARITY_COOLDOWN`. It reads no keys. Tests call `deploy(config, create2Deployer)` directly.

```sh
# refused: wrong chain
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
# local dry run (no RPC): mines the hook salt and deploys four contracts
EXPECTED_CHAIN_ID=31337 POOL_MANAGER=0x000000000000000000000000000000000000dEaD \
PROJECT_OWNER=<owner> CHARITY=<charity> forge script script/Deploy.s.sol:Deploy --offline
# operator-only Sepolia deployment (the operator supplies the signer flags; none are in this repo)
EXPECTED_CHAIN_ID=11155111 POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 \
PROJECT_OWNER=<owner> CHARITY=<charity> forge script script/Deploy.s.sol:Deploy \
  --rpc-url <sepolia-rpc> --broadcast <signer flags>
```

## The hook address requirement (read before writing the manifest)

Uniswap v4 reads a hook's permissions from the low 14 bits of its **address**. `HauntedHook`
needs exactly `afterInitialize | beforeSwap | afterSwap` = **`0x10C0`** (bits 12, 7, 6 set, all
other 14 low bits clear). Its constructor reverts with `HookAddressNotValid` at any other address,
exactly as Uniswap's `BaseHook` does, because a mis-flagged hook would silently never be called.

The ProjectFactory deploys each application contract with CREATE2 at a salt chosen by the
deployer. **The salt for `HauntedHook` must be mined**, which the salt-per-contract design of the
floor tests allows: find `salt` such that

```
address(keccak256(0xff ++ factory ++ salt ++ keccak256(creationCode ++ abi.encode(args))))[12:] & 0x3FFF == 0x10C0
```

where `args` are the five constructor arguments after `$token`, `$owner` and the two vault
addresses are resolved. Expected work is 2^14 ≈ 16k hashes. Tools in this repo:

* `HookSaltMiner.mine(deployer, initCodeHash, 0x10C0, start, maxAttempts)` (pure library);
* `Deploy.mineHookSalt(create2Deployer, poolManager, token, owner, jackpotVault, charityVault)`
  and `Deploy.hookInitCode(...)` return the salt and the exact init code to hash.

The vaults and the token have no address requirement. A copy of the protected floor tests was run
locally against this exact plan (token at salt 1, vaults at salts 2 and 3, hook at a mined salt
from a stand-in factory address); all 8 passed. See REVIEW.md.

## Manifest guidance (for the manifest assignment; this stage does not write `launch.json`)

Kind `evm_project`, token `LaunchToken` (name "Haunted VOID", symbol "VOID", 18 decimals).
Contracts in dependency order, constructor arguments in declaration order:

1. `JackpotVault(address admin, uint256 payoutBps, uint256 cooldownSeconds)` →
   `["$owner", 300, 600]` (3%, 10 minutes; any `payoutBps` in 1..300 and cooldown ≤ 2,592,000 is accepted).
2. `CharityVault(address admin, address charity, uint256 donationBps, uint256 cooldownSeconds)` →
   `["$owner", <charity address chosen by the requester>, 100, 3600]` (1%, 1 hour).
   **Open item:** the brief names no charity address; it must come from the requester or policy.
3. `HauntedHook(address poolManager, address voidToken, address initialOwner, address jackpotVault, address charityVault)`
   → `[<Sepolia v4 PoolManager>, "$token", "$owner", "$contract:JackpotVault", "$contract:CharityVault"]`,
   with a **mined salt** (above).

The Sepolia Uniswap v4 PoolManager is `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` according to
Uniswap's deployment list; this task's read list contains no `network.json`, so it was checked only
by reading it over a public RPC (block 11834262: code present, `owner()` returns
`0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519`). Treat it as unverified until `network.json` or the
deployer confirms it. Nothing is hard-coded: the address is a constructor argument.

Constructors run with the factory as `msg.sender`; nothing here uses `msg.sender` for a role. Every
privileged role is given to `$owner` explicitly. No contract is payable at construction. Runtime
sizes: hook ≈ 9.8 KB, vaults ≈ 4 KB, token ≈ 1.8 KB; no `DELEGATECALL`, `CALLCODE`, `SELFDESTRUCT`.

## What the launch pool is, and what the haunted pool is

The ProjectFactory seeds **its own** ETH/VOID pool (fee 3000, tickSpacing 60, the factory's
`PoolInitializationGuard` hook, opening fee set by the network's LaunchFees). That pool is not
haunted; it is where the launch liquidity lives, and the hook is not involved in it.

The **haunted pool** the brief asks for is a second ETH/VOID pool with `fee = 0x800000` (dynamic),
`hooks = HauntedHook`, any tick spacing (60 suggested), created after launch by the owner or anyone
(`PoolManager.initialize`), and supplied with liquidity by whoever wants to play host. The factory
cannot seed liquidity into a hooked pool, so its liquidity is an operational responsibility. The
website must use the haunted pool's exact `PoolKey` for the game and may show the launch pool
separately.

## Operational steps after the factory deploys (owner responsibilities)

1. `JackpotVault.grantRole(PAYER_ROLE, hook)` and `CharityVault.grantRole(SIGNALER_ROLE, hook)`
   from the owner wallet. Until then jackpot and charity outcomes are recorded as skipped
   (`AccessControlUnauthorizedAccount` in the event's `reason`) and swaps are unaffected.
2. Fund the vaults with test ETH (plain transfer or `fund()`), and the hoard with VOID
   (`approve` + `fundHoard`, or a transfer) from the requester's VOID share.
3. Initialize the haunted pool (`PoolManager.initialize` with the key above and a chosen
   `sqrtPriceX96`) and add liquidity to it.
4. Point the website at the hook, the vaults, the token and the haunted pool key; have it pass
   `abi.encode(user)` as `hookData` on every swap.
5. Optional Sepolia demonstrations: `forceOutcome`, `forceCorruption`, then `clearForcedOutcome`.

## Trust assumptions and known limitations

* **Randomness is predictable.** The draw is `keccak256(seed, block.prevrandao, router, swapper,
  amountSpecified, zeroForOne, swapCount)`; `seed` is the previous draw's hash. Anyone can simulate
  the next outcome and swap only when it is favourable (free swap, jackpot). This is acceptable for a
  testnet game whose downside is bounded by the 3%/1% caps, the cooldowns, the 1%-of-hoard burn cap
  and the fact that the pool's own fee goes to its LPs. It is **not** acceptable for valuable
  jackpots; a VRF-fed seed would be needed, and the hook has no such path by design (a seed anyone
  can set is worse than prevrandao). Unresolved deployment choice: accept this, or scope the jackpot
  reserve to dust.
* **Owner powers** (requested by the brief): force outcomes, set corruption, set the burn share,
  pause vault releases, change caps *downward*, change cooldowns (≤ 30 days), re-point the charity.
  The owner cannot withdraw ETH from the vaults, cannot move the hoard, cannot block swaps, cannot
  raise caps above 3%/1%, and cannot change the token.
* **Timestamp dependence.** Cooldowns compare `block.timestamp`; a proposer can shift it by seconds,
  which only delays or advances a release by that much.
* **Beneficiary spoofing is harmless.** The swapper chooses the `hookData` address, pays the swap,
  and gains nothing beyond directing their own jackpot.
* **Dust swaps** can farm rolls cheaply; the caps and cooldowns bound what they can extract.
* **Vault ETH is unrecoverable** except through capped releases. Intentional.
* **The hoard burn is from game-held VOID**, not from the swapper's output: the hook has no
  `afterSwapReturnDelta` permission and never touches PoolManager deltas, so swap outputs are
  exactly what Uniswap's curve and the overridden fee say. This was chosen over taxing the output
  because the brief forbids transfer taxes and because returns-delta hooks are a theft vector.
* **evm_version is Cancun**, not Paris: the v4 PoolManager uses transient storage and the tests run
  it. Sepolia supports Cancun. The deployer should keep this setting when verifying source.
* **Not asked and not done here:** Sepolia deployment, Etherscan verification, pool creation, the
  website, IPFS publication. These are later stages. No key material, RPC URL or broadcast exists
  in this repository.

## Build and test (offline)

Dependencies are vendored as ordinary files under `lib/` (forge-std, OpenZeppelin Contracts 5.7.0,
Uniswap v4-core 1.0.2 `src/` + `test/utils/CurrencySettler.sol`, solmate for v4-core's `Owned`).
Compiler pinned to solc 0.8.26, optimizer 200 runs, `evm_version = "cancun"`, `bytecode_hash = "none"`.

```sh
forge build --offline
forge test --offline
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline   # refuses: UnsupportedChainId(0)
```

Tests (88): `LaunchToken.t.sol` (supply, transfer, no admin selectors), `Vaults.t.sol` (roles,
caps with fuzz, cooldowns with fuzz, pause, rejecting recipients, reentrancy guard, no withdrawal
selectors), `Vaults.invariant.t.sol` (conservation, cap, cooldown and pause invariants for each
vault), `HauntedHook.t.sol` (address flags, pool admission, every outcome forced and every outcome
reached through the real draw, exact fee charged per outcome checked against Uniswap's swap math,
burn caps with fuzz, jackpot/charity success and every skip path, reentrancy, admin controls,
both swap directions, exact-output swaps, multi-pool state), `HauntedHook.invariant.t.sol`
(random swaps + funding + warps + owner controls: no pending state, corruption bounded, burn and
VOID conservation, vault conservation, caps and cooldowns held), `HookSaltMiner.t.sol`,
`Deploy.t.sol`. Tests read no environment variables and set none.
