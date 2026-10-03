# Review — Haunted Liquidity Pool contracts

Self-review by the implementing seat against `.imd/reads/skills/eth-security/REFERENCE.md` and the
`uniswap-v4-hooks` checklist. It is not an audit and does not replace the workflow's independent
adversarial review, which must still run before anything holding other people's funds is released.

## Scope

`src/LaunchToken.sol`, `src/HauntedVault.sol`, `src/JackpotVault.sol`, `src/CharityVault.sol`,
`src/HauntedHook.sol`, `src/HookSaltMiner.sol`, `script/Deploy.s.sol`, `foundry.toml`, `lib/`.

## What was run

| Check | Result |
|---|---|
| `forge build --offline` (solc 0.8.26, cancun, 200 runs, bytecode_hash none) | ok |
| `forge test --offline` | 88 passed, 0 failed (256 fuzz runs; 3 invariant suites, 48 runs × depth 32, `fail_on_revert = true`, 0 reverts) |
| `forge fmt --check` | ok |
| `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline` | reverts `UnsupportedChainId(0)` |
| `EXPECTED_CHAIN_ID=31337 … forge script … --offline` | deploys 4 contracts; hook lands at `…10C0`, prediction matches |
| Protected floor tests (`Token.protected.t.sol`, `Project.protected.t.sol`) copied to `test/scratch/` and run with a stand-in factory, token at salt 1, vaults at salts 2/3, hook at a mined salt | 8 passed: supply preserved by every constructor, runtimes < 24,576 B, no `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT`, token admin selectors inert |
| `forge lint` | remaining warnings reviewed below; none changes code |
| Slither / Mythril | not available on this seat; not run |

## Findings and dispositions

### F1 — Pending guard cleared before side effects (fixed during development)

`afterSwap` originally deleted the pending record before calling the vaults. A jackpot winner
contract that re-entered `PoolManager.swap` on the haunted pool therefore passed `beforeSwap`,
ran a nested swap and left an unsettled delta (`CurrencyNotSettled`, the outer swap reverted).
Fixed: the pending flag now stays set until the end of `afterSwap`; the nested `beforeSwap`
reverts `SwapAlreadyPending`, the winner's receive fails, the vault reverts `TransferFailed`, the
hook emits `JackpotSkipped` and the swap completes. Regression test:
`test_nestedSwapDuringPayoutIsRejected`, plus `test_pendingGuardDirect`.

### F2 — Hook address permissions (design constraint, documented)

The hook only works at an address with low bits `0x10C0`, and the constructor refuses any other.
The ProjectFactory's salt for `HauntedHook` must be mined (README "The hook address requirement").
If the manifest/deployer cannot choose a salt, the launch transaction reverts in the hook
constructor; nothing partial is deployed. Disposition: documented as a blocking deployment
parameter; mining helpers shipped; the floor plan was reproduced locally with a mined salt.

### F3 — Weak randomness (accepted, documented)

`block.prevrandao` plus swap parameters is simulable by the swapper. Exposure: a swapper can wait
for a free swap or a jackpot (≤ 3% of the reserve, once per cooldown). Disposition: accepted for a
testnet game with explicit README warning and an unresolved-choice note; a seed set by callers was
rejected as worse. No VRF path exists in the design.

### F4 — Charity address and owner are policy inputs (open item for the manifest)

`CharityVault` needs a nonzero charity address and both vaults and the hook need `$owner`. The
brief names neither. Disposition: constructor arguments, never hard-coded; the manifest assignment
must obtain them from policy/requester.

### F5 — PoolManager address unverified against `network.json` (open item)

No `network.json` was supplied. The Sepolia v4 PoolManager `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`
was read over a public RPC (code present at block 11834262, `owner()` answers) but not confirmed
against network policy. Disposition: constructor argument; flagged as unverified in the README.

### F6 — Post-deploy role grant required (documented operational step)

The hook needs `PAYER_ROLE`/`SIGNALER_ROLE` on the vaults, which cannot be granted in constructors
because of the circular dependency (vaults ← hook ← vaults) and because the factory makes no
initialization calls. Until the owner grants them, jackpot and charity outcomes are recorded as
skipped and swaps are unaffected (tested: `test_jackpotSkippedWithoutRole`). Alternative considered
and rejected: the hook deploying the vaults in its constructor (unverified child contracts, larger
runtime).

### F7 — Jackpot to the router when `hookData` is empty (documented frontend contract)

Without `hookData`, the beneficiary is the router. Real routers either cannot receive ETH (payout
skipped, cooldown not consumed) or would strand it. Disposition: frontend must pass
`abi.encode(user)`; tested both ways (`test_forcedJackpotPaysSwapperFromHookData`,
`test_jackpotFallsBackToRouterWithoutHookData`, malformed-data case).

### F8 — Lint warnings reviewed

* `weak-prng` (hook draw): F3.
* `arbitrary-send-eth` (`HauntedVault._release`): the destination is the swapper chosen by the
  payer role or the admin-set charity; the amount is capped; by design.
* `locked-ether` (`HauntedVault`): no admin withdrawal is intentional (README).
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
* Upgradeability / selfdestruct: none; floor tests confirm the runtimes.
* Pausable: vaults only; swaps cannot be paused (documented trust assumption).
* Deployment items that belong to the deployer: explorer verification, salt mining for the hook,
  owner wallet from policy, charity address from requester.

## Residual risks for the independent reviewer

1. Randomness (F3) and whether the jackpot funding level is acceptable given it.
2. Game-state sharing across several haunted pools: a second pool with odd tick spacing shares
   corruption and counters. Harmless to funds; worth a conscious decision.
3. Anyone can initialize additional haunted ETH/VOID pools; `afterInitialize` does not restrict
   the initializer. No funds at risk, but the site must pin one `PoolKey`.
4. The hook's `hookData` beneficiary is self-declared; only the swapper's own jackpot is affected.
