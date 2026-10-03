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
| `HauntedGame` | `src/HauntedGame.sol` | Funded trade commitments, future beacon draws, LP fees and pull refunds |
| `HauntedDeployment` | `src/HauntedDeployment.sol` | Constructor-only bundle that mines the hook salt and grants vault roles atomically |
| `HookSaltMiner` | `src/HookSaltMiner.sol` | Pure CREATE2 salt mining for the hook's permission bits (used by script and tests) |

ABIs: `docs/abi/LaunchToken.json`, `docs/abi/HauntedHook.json`, `docs/abi/JackpotVault.json`,
`docs/abi/CharityVault.json`, `docs/abi/HauntedGame.json`, `docs/abi/HauntedDeployment.json`.

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

Exactly one ETH/VOID pool is admitted. It must use this hook, the dynamic-fee flag
(`0x800000`), tick spacing **60** and opening `sqrtPriceX96 = 2^96` (1:1 in minor units).
Initialization is permissionless only at those exact parameters. An outsider cannot choose another
opening price, admit a second pool or use an empty rogue pool to drive the game. Operators should
check whether the canonical pool already exists before initializing it. Its market price can change
normally after initialization; enforce price/slippage limits when adding liquidity.

* **afterInitialize** validates this canonical configuration, sets the opening LP fee to 0.30% and
  emits `PoolHaunted`.
* **beforeSwap** selects the committed game's outcome and fee, or an owner-forced demo outcome.
  Ordinary router trades use `NormalTrade` and pay 0.30%; they do not draw or change game corruption.
* **afterSwap** applies game effects only when tokens actually moved, emits the outcome and
  `SwapResolved`, then clears pending state. Failed committed trades emit `HauntedGame.TradeFailed`
  and do not apply game effects.

**Game trades now use two transactions separated by a future draw.** Call `hook.game().commit`
with the full input and a fixed minimum output. A keeper captures the beacon at the exact target
block, 128 blocks after commitment; anyone can execute after that block. The player and trade
parameters cannot change. Fees come from escrow and are donated to LPs before the isolated swap;
the hook applies a zero additional LP fee to avoid charging twice. Failed swaps still pay their
drawn fee. Missing entropy refunds the input less the maximum 5% fee, with no reroll.
Outputs and refunds are claimed through `withdraw`. See [the game protocol](docs/game.md) for the
complete state machine, failure paths, fee rounding and keeper duties. The frontend must disclose
the delay and failure fee before accepting a commitment.

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

Corruption is capped at 100, so the corrupted fee reaches its 5% ceiling at level 94. Game roll
bands and fees use the level captured at commitment. Forced demos use the pre-swap level.
`CorruptedFee` emits that pricing level; `SwapResolved` emits the post-effect current level.
Every swap emits `SwapResolved(poolId, swapper, outcome, fee, roll, forced, corruption, swapIndex)`.
For ordinary trades, `roll = 0` is a placeholder, not a draw. For game trades, the fee field describes
the escrowed LP fee; the Uniswap swap itself uses a zero additional LP fee.

*Burn limits.* A burn is `burnBps` (default 1%, owner-settable up to 5%) of the VOID moved by the
swap, never more than 1% of the hoard per event. The hoard is VOID held by the hook, funded by
anyone (`fundHoard(amount)` after an approval, or a plain transfer). The hook can send VOID only to
the dead address; there is no withdrawal. An empty hoard or `burnBps = 0` yields `BurnSkipped`.

*Vault calls never block a swap.* Jackpot and charity calls are wrapped in `try/catch`; a paused,
empty, cooling-down or role-less vault, or a winner that rejects ETH, produces a `…Skipped` event
with the vault's revert data and the swap completes.

*Who is the swapper?* For ordinary/forced trades, only a canonical 32-byte nonzero address in
`hookData` names a beneficiary. Missing, zero or malformed data yields address zero and
`JackpotSkipped(MissingBeneficiary)` without calling the vault or consuming its cooldown. The router
is never substituted. A committed game's beneficiary is the address that deposited its input;
executors cannot substitute themselves.

*Owner test controls (Sepolia).* `forceOutcome(outcome)` makes every swap resolve to that outcome
until `clearForcedOutcome()`; `forceCorruption(0..100)` sets the level; `setBurnBps(0..500)`.
Ownership is two-step (`Ownable2Step`); renouncing clears any forced outcome and pending owner.
Overrides never change an existing game commitment. Nothing else is privileged; in particular the owner cannot
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
  vault) is **granted atomically by HauntedDeployment**. The bundle relinquishes all of its own
  roles before construction completes. Standalone vault/hook deployments remain low-level building
  blocks and require explicit role grants; they are not the canonical launch path.
* Caps: a release is `releaseBps` of the reserve at call time, `0 < releaseBps ≤ MAX_RELEASE_BPS`;
  the maximum is an immutable set per vault — **300 bps (3%) for jackpots, 100 bps (1%) for
  donations** — and the admin can only lower the share below it, never raise it above.
* Cooldowns: `block.timestamp ≥ lastReleaseAt + cooldown`, **1 second ≤ cooldown ≤ 30 days**,
  admin-settable. Constructors and setters both reject zero. The first release is immediate.
* Pause: `PAUSER_ROLE` pauses releases; funding stays open.
* Funding: permissionless, `receive()` or `fund()`.
* **Admin trust:** the admin can grant itself a trigger role, direct the charity to itself and
  receive `releaseBps` of reserves once per configured cooldown. There is no uncapped withdrawal,
  but reserves can be depleted over repeated capped releases. The minimum cooldown is only one
  second; donors must trust the admin and its settings. Admins may raise shares back to their caps.
* Release recipients cannot be zero or the releasing vault itself. `setCharity` enforces both
  checks. Naming the other vault as a jackpot recipient remains an explicit donation to that vault.

### Deploy script

`script/Deploy.s.sol` is for a local chain or an operator-run Sepolia test deployment; the
production launch goes through the network's ProjectFactory and does not use it. `run()` reads
`EXPECTED_CHAIN_ID` (must equal the connected chain and be 31337 or 11155111), `POOL_MANAGER`,
`PROJECT_OWNER`, `CHARITY` and optional `JACKPOT_BPS`, `JACKPOT_COOLDOWN`, `CHARITY_BPS`,
`CHARITY_COOLDOWN`. It reads no keys. Tests call `deploy(config)` directly. Both script and canonical launch deploy a `HauntedDeployment`
bundle, which creates both vaults, the hook and its game router with complete role wiring.

```sh
# refused: wrong chain
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
# local dry run (no RPC): deploys the token and constructor bundle
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

The canonical launch now lists **HauntedDeployment**, whose constructor creates the vaults,
mines the child hook salt against its own actual address and exact init code, creates the hook
(and its immutable game router), grants the hook its trigger roles, and hands vault administration
to `$owner`. No post-construction initialization call is needed. The outer bundle address requires
no special bits; the service can use an ordinary CREATE2 salt.

Salt search is bounded at 1,000,000 candidates and reuses one buffer to avoid quadratic memory
costs. Expected work is about 16,384 hashes, but the exact deployment must be gas-estimated: the
number of candidates varies with the bundle address and resolved constructor inputs. If an outer
salt gives an estimate above the network transaction budget, select another ordinary outer salt
and simulate again. The bundle still performs the hook mining itself. No successful deployment
can contain an incorrectly flagged hook or incomplete vault role grants.

`HookSaltMiner.mine`, `Deploy.mineHookSalt` and `Deploy.hookInitCode` remain available for standalone
experiments. Deploying `HauntedHook` directly at an arbitrary salt still correctly reverts.

## Manifest guidance (source handoff; this assignment does not write launch.json)

Kind `evm_project`, token `LaunchToken` (Haunted VOID, VOID, 18 decimals). Replace the previous
three application entries (two vaults and a directly deployed hook) with **one** entry:

`HauntedDeployment(address poolManager, address token, address owner, address charity,
uint256 jackpotBps, uint256 jackpotCooldown, uint256 charityBps, uint256 charityCooldown)`

Constructor arguments in order:

`[<verified network PoolManager>, "$token", "$owner", <approved charity>, 300, 600, 100, 3600]`

The charity and PoolManager are explicit deployment inputs. Obtain them from the requester/policy
and network configuration; no privileged wallet is hard-coded. Do not list child contracts as
separate application deployments. Read `hook()`, `jackpotVault()`, `charityVault()`, `hookSalt()`
from the bundle and `game()` from the hook for the deployment handoff. Export and verify the child
sources as well as the bundle. All constructors are nonpayable; none moves the launch-token supply.

The separate manifest assignment must regenerate and review `launch.json` against this constructor
shape. A manifest still deploying the old three entries does not describe this revision. Policy,
attestation linkage, admission and actual deployment remain service responsibilities.

## What the launch pool is, and what the haunted pool is

The ProjectFactory seeds **its own** ETH/VOID pool (fee 3000, tickSpacing 60, the factory's
`PoolInitializationGuard` hook, opening fee set by the network's LaunchFees). That pool is not
haunted; it is where the launch liquidity lives, and the hook is not involved in it.

The **haunted pool** the brief asks for is a second ETH/VOID pool with `fee = 0x800000` (dynamic),
`hooks = HauntedHook`, tick spacing 60, and opening price `2^96`, created after launch by the owner
or anyone at exactly those parameters and supplied with liquidity by whoever wants to play host. The factory
cannot seed liquidity into a hooked pool, so its liquidity is an operational responsibility. The
website must use the haunted pool's exact `PoolKey` for the game and may show the launch pool
separately.

## Operational steps after the factory deploys (owner responsibilities)

1. Confirm the bundle's child addresses, vault role grants and owner roles. Do not grant roles to
   the factory or leave bundle administrative authority behind.
2. Fund the vaults with test ETH and the hoard with VOID (`approve` + `fundHoard`, or a transfer).
3. Initialize the canonical haunted pool if absent, then add liquidity with explicit price limits.
4. Configure the website with the exact haunted PoolKey and `hook.game()` address. Use direct
   router swaps for base-fee trades, and the game commitment/withdrawal flow for randomized trades.
5. Run a keeper for exact-target entropy capture, permissionless execution and deferred LP fee
   delivery. Missing capture costs players the maximum fee. Display this before accepting funds.
6. Optional Sepolia demonstrations: force an outcome or corruption, then clear the override.

## Trust assumptions and known limitations

* **Future beacon entropy is a testnet assumption, not a VRF.** Funded game parameters are fixed
  128 blocks before the beacon capture. A swapper cannot select a roll by changing its amount in the
  execution transaction. Block proposers can still bias/censor beacon capture; see
  [EIP-4399 security considerations](https://eips.ethereum.org/EIPS/eip-4399#security-considerations).
  There is no secure-randomness claim for valuable funds. A keeper must capture the exact block;
  failure produces the documented maximum-fee refund, not a fresh draw.
* **Owner powers** include forcing direct demo outcomes (including free swaps or jackpots), setting
  corruption and burn share, pausing vaults, adjusting shares within their caps and cooldowns in
  1 second..30 days, changing charity, and granting trigger roles to itself. It can receive capped
  releases repeatedly. It cannot move the hoard, change the token or change committed draws.
* **Timestamp dependence.** Cooldowns compare `block.timestamp`; a proposer can shift it by seconds,
  which only delays or advances a release by that much.
* **Beneficiary choice.** Direct demo swaps may direct a jackpot through explicit `hookData`. Game
  ticket beneficiaries are fixed to the depositor. Self-payouts to the releasing vault are refused.
* **Dust commitments** can still farm many future draws cheaply. This fix prevents submission-time
  selection; it does not make the bankroll economically safe. Repeated wins, admin-forced outcomes
  or admin-triggered releases can ultimately exhaust it. Fund only expendable test ETH.
* **Vault ETH is unrecoverable** except through capped releases. Intentional.
* **The hoard burn is from game-held VOID**, not from the swapper's output: the hook has no
  `afterSwapReturnDelta` permission and never touches PoolManager deltas, so swap outputs are
  exactly what Uniswap's curve and the overridden fee say. This was chosen over taxing the output
  because the brief forbids transfer taxes. Committed trade fees are separately charged from input
  escrow; the hook still has no returns-delta permissions.
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

Tests include token supply/transfers, all eight forced and delayed outcomes, canonical pool admission,
invalid beneficiaries, vault caps/pauses/cooldowns/self-recipients, ownership renunciation, constructor
wiring and runtime opcode bounds. Game tests cover early/repeated execution, immutable draw parameters,
failed trades retaining fees, missed captures, pull refunds, both currencies, no-liquidity fee deferral,
withdrawal failure and reentrancy. Four invariant suites check vault, hook and game conservation and
bounds (48 runs × 32 calls); fuzz tests use 256 runs. Tests read/set no environment variables.

The revision also reruns the four supplied immutable proof files from `test/scratch/`: all six proof
tests pass. `.imd-responses.json` records a disposition and evidence for all ten reported findings.
