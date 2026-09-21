# Lastlight

A small survival game on Sepolia. Participants lock LAST in the **Tontine** during a
30-day joining window, then must prove they are still around by pinging at least once every
30 days. Anyone may evict a participant who goes quiet. When only one participant is left after
the joining window has closed, they take the whole pot.

This repository is the contract stage of the launch: the token, the application contract, the
Foundry test suite and the ABI exports. The launch manifest (`launch.json`), the independent
reviews, GitHub publication, deployment through ProjectFactory and the website are separate
assignments and are **not** part of this deliverable.

## Layout

| Path | What it is |
| --- | --- |
| `src/Lastlight.sol` | The LAST token: fixed supply, 18 decimals, no constructor arguments, no admin. |
| `src/Tontine.sol` | The application contract. Constructor takes only the token address. |
| `src/IERC20.sol` | The ERC-20 surface the two contracts share. |
| `test/Lastlight.t.sol` | Token behaviour: supply, metadata, transfers, allowances, absence of mint/admin paths. |
| `test/Tontine.t.sol` | Every Tontine path: success, failure, timing boundaries, conservation, reentrancy, settlement failure. |
| `test/mocks/MaliciousToken.sol` | Adversarial tokens used only by tests (re-entrant and false-returning). |
| `docs/abi/Lastlight.json`, `docs/abi/Tontine.json` | ABI exports (`forge inspect <Contract> abi --json`). |
| `lib/forge-std/` | Vendored forge-std v1.9.7 as ordinary files, so the suite builds offline. |
| `foundry.toml` | solc 0.8.26, `bytecode_hash = "none"`, `ffi = false`, no filesystem permissions. |

```
forge build
forge test
forge fmt --check
```

All three run offline; the compiler is pinned to 0.8.26 and no dependency is fetched.

## Lastlight (LAST)

- Name `Lastlight`, symbol `LAST`, 18 decimals.
- `TOTAL_SUPPLY = 1_000_000_000e18` (10^27 minor units, exactly 1,000,000,000 LAST), minted
  once in the constructor to `msg.sender`. Under ProjectFactory that is the factory, which
  splits the supply according to launch policy. `totalSupply()` is a constant.
- No constructor arguments, no owner, no mint, no burn, no pause, no upgrade, no hooks.
- Standard `transfer`, `approve`, `transferFrom`. An allowance of `type(uint256).max` is
  treated as unlimited and never decremented. Transfers to the zero address and approvals of
  the zero spender revert with custom errors. Transfers move exactly the requested amount
  (no fee on transfer), which the Tontine's accounting relies on.

## Tontine

### Constants and constructor

| Item | Value | Notes |
| --- | --- | --- |
| `OPEN_PERIOD` | 30 days | Joining allowed while `block.timestamp < openUntil`. |
| `PING_INTERVAL` | 30 days | A participant is overdue when `block.timestamp > lastPing + 30 days`. |
| `token` | constructor argument | Immutable. Must be non-zero. Manifest passes `$token`. |
| `openUntil` | `deployTime + OPEN_PERIOD` | Immutable, set from the block in which the factory deploys. |

Both durations are compile-time constants because the approved requirements allow only the
token address as a constructor argument. Changing either means editing the source, rebuilding
and re-reviewing.

### Rules as implemented

1. **join(amount)** — deposits `amount` LAST (via `transferFrom`, so the caller must approve
   first). Reverts on `amount == 0` (`ZeroAmount`), once the window has closed
   (`JoiningClosed`), or if the caller is already in (`AlreadyJoined`). One entry per address;
   there are no top-ups. Any positive amount is accepted: stake size does not affect the odds,
   only survival does. The join timestamp counts as the first ping.
2. **ping()** — participant only (`NotParticipant` otherwise). Sets `lastPingOf[msg.sender]`
   to now. An overdue participant who has not yet been evicted can still ping and become safe
   again; eviction is never automatic.
3. **evict(participant)** — callable by anyone, including other participants and the evictee.
   Requires the target to be a participant, to be overdue, and to not be the last one standing
   (`NotOverdue` / `CannotEvictLast`). The deposit is forfeited and stays in the pot. Evictors
   receive nothing.
4. **claim()** — callable only by the sole remaining participant, only once
   `block.timestamp >= openUntil`. Pays the entire pot with `transfer`, records `winner`, and
   empties the roster. After a claim nothing further can happen: joining is closed, there are
   no participants to ping or evict, and `pot` is zero.

Boundaries, all covered by tests:

- Join at `openUntil - 1` succeeds; at `openUntil` it reverts.
- Claim at `openUntil - 1` reverts (`StillOpen`); at `openUntil` it succeeds.
- Evict at exactly `lastPing + 30 days` reverts; at `+ 30 days + 1` it succeeds.

Consequences of the chosen constants:

- Because `OPEN_PERIOD <= PING_INTERVAL`, nobody can be overdue while joining is still open.
  The game therefore has two clean phases: a joining phase in which no eviction is possible,
  then an attrition phase in which nobody new can enter. An evicted participant can never
  rejoin.
- A sole entrant simply reclaims their own deposit once the window closes.
- The last participant is never evictable, so a funded pot always has exactly one address
  that can claim it. Funds cannot be stranded by "everyone got evicted".

### Events

Every state change emits an event: `Joined(participant, amount, pot)`,
`Pinged(participant, timestamp)`, `Evicted(participant, by, forfeited)`,
`Claimed(winner, amount)`. There are no other writes.

### Views for the website

`isOpen()`, `openUntil()`, `pot()`, `winner()`, `participants()` (address array, unordered),
`participantCount()`, `isParticipant(a)`, `depositOf(a)`, `lastPingOf(a)`, `deadlineOf(a)`,
`canEvict(a)`, `canClaim(a)`. The roster uses swap-and-pop removal, so ordering is not stable
across evictions; sort client-side if a stable order is wanted.

### Security posture

- No owner, admin, fee, withdrawal, pause, upgrade, `DELEGATECALL`, `CALLCODE` or
  `SELFDESTRUCT`. No `receive`/`fallback`, so ETH sent to it reverts.
- Checks-effects-interactions everywhere. The only external calls are `token.transferFrom`
  (end of `join`) and `token.transfer` (end of `claim`), both after all state is written and
  events are emitted. Re-entrant `join`, `ping`, `evict` and `claim` attempts from inside a
  malicious token are tested; all of them see the already-updated state and revert (a
  re-entrant `join` by the token *itself* simply makes the token a regular participant, which
  is also tested).
- A transfer that returns `false` reverts the whole call (`TransferFailed`), so a failed payout
  leaves the winner in place to retry; nothing is marked paid until the token agrees.
- No randomness is used or needed: the outcome is decided purely by who keeps pinging.

Things a reviewer should weigh, none of which the contract tries to hide:

- **Eviction ordering is first-come.** If two remaining participants are both overdue, whoever
  submits the first `evict` picks the winner. Participants who ping on time are never exposed
  to this.
- **Sybil entries are allowed but pointless.** Many addresses cost many pings; one address that
  keeps pinging is as good as a thousand.
- **Stake size is irrelevant to the odds.** A 1-wei entrant can win a large pot by outlasting
  everyone. That is the tontine.
- **Timestamps.** Validators can nudge `block.timestamp` by seconds; all windows here are 30
  days, so this is immaterial (the `block-timestamp` lint is excluded in `foundry.toml` for
  that reason).
- **Token trust.** The constructor accepts any address. The accounting assumes a standard,
  bool-returning, non-rebasing, no-fee ERC-20 — which LAST is. The manifest must pass
  `$token` and nothing else.

## Tests

68 tests, all passing locally (`forge test`), with fuzzing on transfer conservation and on
join/evict/claim conservation over 1–12 participants. Coverage by category:

- Token: metadata, fixed supply, deployer receives everything, no admin selectors, transfer
  and allowance success/failure, infinite allowance, zero-address guards, fuzzed conservation.
- Tontine: construction (including zero-token revert and untouched factory supply), join
  (success, zero, no approval, no balance, duplicate, both timing edges, no rejoin), ping
  (success, non-participant, after eviction, after claim, overdue revival), evict (success,
  by anyone/self, both timing edges, deadline follows the latest ping, non-participant, last
  participant, no eviction during the open phase, no double eviction, swap-and-pop roster
  integrity), claim (success, sole entrant, both timing edges, others remain, non-participant,
  evicted, twice, nothing works afterwards, sole survivor need not ping), a full lifecycle,
  fuzzed conservation, five reentrancy scenarios through a malicious token, two settlement
  failure scenarios through a false-returning token, absence of admin surface, ETH rejection.

The protected floor suites in `.imd/reads/protected/evm_project/` were also run against the
compiled bytecode through a simulated CREATE2 factory (token salt `1`, one application with
`$token`); all 8 checks pass. Passing tests are not an audit: the independent adversarial
review is a separate step before deployment.

## Deployment parameters (for the manifest node and reviewers)

The manifest assignment owns `launch.json`; this section records what the source requires of it.

- Kind: `evm_project`. Chain: Sepolia, `11155111`.
- Launch token: `Lastlight` (`src/Lastlight.sol`), no constructor arguments, 18 decimals,
  supply 10^27. The factory must observe the full supply on its own balance after the
  constructor; nothing in `Tontine`'s constructor moves tokens.
- Application contracts, in dependency order — exactly one:
  - `Tontine` (`src/Tontine.sol`), `constructorArgs: ["$token"]`. It takes no owner and has no
    privileged role, so `$owner` must **not** appear anywhere.
- Pool parameters per policy: pair against native ETH, fee 3000, tick spacing 60, initial
  sqrtPriceX96 `79228162514264337593543950336`. These are pool parameters, not a valuation.
- Compiler settings that must be reproduced for the attested bytecode: solc 0.8.26, optimizer
  on, 200 runs, `evm_version = "cancun"`, `bytecode_hash = "none"`.
- `openUntil` is fixed at deployment time: joining ends exactly 30 days after the block in
  which the factory deploys the Tontine. The website should read `openUntil()` rather than
  assume a date.

Neither this assignment nor any contributor holds keys, signs or broadcasts anything.

## Operational responsibilities

- **Participants** must ping at least every 30 days from their last ping (or join). Missing
  it does not evict them automatically, but it lets anyone do so. The website should show
  `deadlineOf` prominently.
- **Anyone** may keep the game honest by evicting overdue participants; there is no reward for
  doing so and no operator that will do it on their behalf.
- **The winner** must call `claim()` themselves; nobody can claim for them, and there is no
  deadline for claiming.
- **Nobody** can pause, upgrade, refund, change the token, or move funds. If the deployed
  constants turn out to be wrong, the remedy is a new deployment, not an intervention.
- **Unresolved choices**, decided here and open to reversal before deployment by editing the
  source: `OPEN_PERIOD = 30 days`, `PING_INTERVAL = 30 days`, no minimum stake, one entry per
  address, evictors unrewarded, sole survivor un-evictable.
