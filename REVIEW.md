# Review — Haunted Liquidity Pool contracts

Self-review by the implementing seat against `.imd/reads/skills/eth-security/REFERENCE.md` and the
`uniswap-v4-hooks` checklist. It is not an audit and does not replace the workflow's independent
adversarial review, which must still run before anything holding other people's funds is released.

## Scope

`src/LaunchToken.sol`, `src/HauntedVault.sol`, `src/JackpotVault.sol`, `src/CharityVault.sol`,
`src/HauntedHook.sol`, `src/HauntedGame.sol`, `src/HauntedDeployment.sol`, `src/HookSaltMiner.sol`, `script/Deploy.s.sol`, `foundry.toml`, `lib/`.

## Revision verification

The original four reviewer proofs were copied unchanged to `test/scratch/`. All six tests failed
on the starting tree with the reported outcome-selection, rogue-pool, cooldown and router-payment
assertions. They now all pass. Baseline scratch checks also confirmed self-release accounting,
forced-outcome renunciation, code-less vault acceptance and failure at an unmined hook salt.
The existing corrupted-fee test explicitly paired fee 8000 with post-increment level 15; it now
asserts the pricing level 10. Standalone vault constructors grant no hook trigger roles; the revised
launch path completes those grants in its bundle constructor.

Current checks: `forge build`, `forge test`, `forge fmt --check` with solc 0.8.26, Cancun, optimizer
200, metadata hash none. Four invariant suites run 48 × 32 calls; fuzz tests run 256 cases.
Revision tests scan the bundle and all child runtime code for forbidden opcodes and EIP-170 size,
preserve the token supply, and exercise a launch bundle at arbitrary outer salt 4. No live deployment,
transactions, Slither or Mythril were run. The old round's protected-floor result is historical;
this revision's local constructor/opcode/supply checks use explicit inputs and no environment reads.

## Findings and dispositions

### F1 — Pending guard cleared before side effects (fixed during development)

`afterSwap` originally deleted the pending record before calling the vaults. A jackpot winner
contract that re-entered `PoolManager.swap` on the haunted pool therefore passed `beforeSwap`,
ran a nested swap and left an unsettled delta (`CurrencyNotSettled`, the outer swap reverted).
Fixed: the pending flag now stays set until the end of `afterSwap`; the nested `beforeSwap`
reverts `SwapAlreadyPending`, the winner's receive fails, the vault reverts `TransferFailed`, the
hook emits `JackpotSkipped` and the swap completes. Regression test:
`test_nestedSwapDuringPayoutIsRejected`, plus `test_pendingGuardDirect`.

### F2 — Hook address permissions (fixed deployment path)

The hook retains its correct address-bit check. `HauntedDeployment` mines the child salt from its
own actual address and exact init code, creates the hook and exposes its address. The manifest lists
the bundle, so the deployment service no longer needs an undocumented hook-salt mining capability.
The pure miner now reuses memory. Exact constructor gas still depends on salt-search length and must
be simulated against network limits; another outer salt may be selected if needed. No partial launch
survives a constructor failure. Child sources/ABIs remain available for independent verification.

### F3 — Selectable draws (fixed submission-time attack; beacon risks remain)

The original draw was fully selectable within the swap transaction, not merely a matter of waiting
for a lucky block. It could produce 20/20 free swaps and extract 3% of the jackpot on demand each
cooldown (about 98.7% per day at 600 seconds). That description supersedes the prior accepted risk.

Ordinary swaps now pay BASE_FEE and do not draw or alter game state. `HauntedGame` escrows input and
fixes the player, minOut, direction and pricing corruption before a beacon capture 128 blocks later.
Anyone may execute after capture. Fees are deducted before the isolated swap call; slippage failure
cannot avoid a losing fee. Missed capture costs the maximum fee; captured tickets cannot expire or
reroll. See docs/game.md for accounting and keeper duties. All eight delayed outcomes are tested.

Residual assumptions: this is a future beacon draw, not VRF. Validators can bias/censor and keepers
can miss capture. Dust commitments remain economically farmable, and cooldown ordering is not fair
lottery allocation. Use expendable test ETH only. Owner demo controls still deliberately force direct
outcomes; forcing is visible and does not override a committed ticket's draw.

### F4 — Charity address and owner are policy inputs (open item for the manifest)

`CharityVault` needs a nonzero charity address and both vaults and the hook need `$owner`. The
brief names neither. Disposition: constructor arguments, never hard-coded; the manifest assignment
must obtain them from policy/requester.

### F5 — PoolManager address unverified against `network.json` (open item)

No `network.json` was supplied. The Sepolia v4 PoolManager `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`
was read over a public RPC (code present at block 11834262, `owner()` answers) but not confirmed
against network policy. Disposition: constructor argument; flagged as unverified in the README.

### F6 — Missing trigger roles after launch (fixed)

The bundle creates the vaults with itself as temporary admin, creates the hook, grants both trigger
roles, hands admin/pauser roles to the explicit policy owner and renounces its own roles, all inside
one constructor. The bundle runtime cannot administer the children. Both the manifest guidance and
the local Deploy script use this path. Low-level standalone constructors still need manual wiring;
they are not the launch configuration.

### F7 — Missing beneficiary paid the router (fixed)

Missing, zero, wrong-length or noncanonical ABI address data now yields no beneficiary. A jackpot
emits JackpotSkipped without calling the vault. A game ticket fixes its beneficiary to the depositor.
The immutable proof's ETH-receiving router receives no jackpot. Self-recipients are also refused in
both vault release and charity configuration, preserving the reserve/released accounting invariant.

### F9 — Cooldown and owner assurances (fixed)

Both constructor and setter enforce 1 second..30 days. `releaseCount`, rather than timestamp zero,
identifies the first payout, so a timestamp-zero release cannot bypass the cooldown. Admins may still
grant themselves trigger roles and redirect charity; README/NatSpec now explicitly say that they
can receive capped releases repeatedly. There is no promise of admin-inaccessible reserves.

### F10 — Additional advisory hardening (fixed)

Renouncing ownership clears a forced outcome and pending owner. Hook construction requires deployed
code at both immutable vault addresses. CorruptedFee reports its pricing level; SwapResolved retains
its documented post-effect level. Regression tests cover each behavior.

### F8 — Lint warnings reviewed

* Beacon dependence: F3; exact future-block capture, funded commitments and immutable stored entropy.
* `arbitrary-send-eth` (`HauntedVault._release`): the destination is the swapper chosen by the
  payer role or the admin-set charity; the amount is capped; by design.
* `locked-ether` (`HauntedVault`): ETH exits through capped releases; admin self-grants remain possible.
* Game fee restoration after a failed donation occurs under a nonReentrant entry point; a failing
  PoolManager unlock rolls back its transfers before the counters are restored.
* Permissionless execution supplies a fixed swap gas budget, checked with an EIP-150 margin.
  An underfunded executor cannot force a paid failure by starving the swap subcall.
* Game withdrawal destinations belong to the caller's own credited balance; CEI plus nonReentrant.
* Game numeric casts are bounded by int128 input limits and positive output checks. Miner scratch
  memory occupies a single allocated 128-byte buffer; prediction is checked against actual CREATE2.
* `unsafe-typecast` (hook): `uint128(-amount1)` on an `int128` after a sign check and
  `uint24(fee)` after a `> MAX_FEE` check; both bounded.
* `missing-events-arithmetic`: events are emitted in the private setters; false positive.
* `reentrancy-events` and `block-timestamp`: excluded in `foundry.toml` with the reason stated there.

## Checklist walk (eth-security REFERENCE)

* Reentrancy: vault releases are `nonReentrant` and update state before the ETH call; the hook's
  pending flag spans both callbacks (F1). Tests: `test_reentrantPayoutIsBlocked`,
  `test_nestedSwapDuringPayoutIsRejected`.
* Access control: OpenZeppelin `AccessControl` on vaults, `Ownable2Step` on the hook; callbacks
  `onlyPoolManager`; no `tx.origin`; no `msg.sender`-as-owner in constructors.
* Arithmetic: Solidity 0.8 checked math; bps math uses integer division rounding down (caps hold).
* External calls: vault → winner (`call`, success checked); hook → vaults (`try/catch`, immutable
  targets); hook → VOID (`SafeERC20`, standard token).
* Oracle/price manipulation: the hook reads no prices; fee overrides are bounded (≤ 5%).
* Denial of service: a failing vault or recipient cannot block swaps; the hook makes no loops over
  unbounded data.
* Token assumptions: VOID is a plain OZ ERC-20 (no fee-on-transfer, no rebasing); the hook is
  bound to it by constructor and refuses other pairs.
* Upgradeability / selfdestruct: none; local runtime scans cover the bundle and every child.
* Pausable: vaults only; swaps cannot be paused (documented trust assumption).
* Deployment items that belong to the deployer: explorer verification, salt mining for the hook,
  owner wallet from policy, charity address from requester and keeper operations.

## Residual risks for the independent reviewer

1. Future beacon bias/censorship, exact-block keeper availability and the maximum-fee missed-capture
   refund. This is a documented testnet mechanism, not verifiable cryptographic randomness suitable
   for valuable jackpots. Many dust commitments can still exhaust a reserve over time.
2. Full owner authority over forced demo outcomes, vault roles, charity and cooldowns down to one
   second. Funding is permissionless, but donors must trust the admin.
3. One canonical haunted pool, fixed initial 1:1 price and permissionless initialization only at that
   key/price. An outsider cannot set an arbitrary opening price. Normal trading can change its price
   before the operator adds liquidity, which requires slippage protection.
4. The manifest must list HauntedDeployment instead of the old separate application entries; it must
   use approved charity/owner/PoolManager inputs. Exact constructor gas and all predicted child
   addresses require simulation and publication by the service. The manifest is a separate assignment.
5. LP fees from failed/missed game trades are retained and donated to active liquidity. If liquidity
   is absent they wait for `flushFees`; whoever is active then receives them, not historical LPs.
   Player refunds are independent of this delivery. The frontend must disclose fees before commitment.
