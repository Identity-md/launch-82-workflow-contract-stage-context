# Handshake

A two-contract protocol for Sepolia: the fixed-supply token **SHAKE** and **TimeoutEscrow**, an
escrow with a deadline and no operator.

| Contract        | Source                    | ABI                            | Role                                     |
| --------------- | ------------------------- | ------------------------------ | ---------------------------------------- |
| `Handshake`     | `src/Handshake.sol`       | `docs/abi/Handshake.json`      | Launch token, SHAKE, 18 decimals         |
| `TimeoutEscrow` | `src/TimeoutEscrow.sol`   | `docs/abi/TimeoutEscrow.json`  | Escrow of SHAKE between buyer and seller |

`src/IERC20.sol` holds the ERC-20 interface both use, so the project vendors no token library.

## Handshake (SHAKE)

Zero-argument constructor. It mints `INITIAL_SUPPLY = 1_000_000_000e18` — 1,000,000,000 SHAKE in
10^27 minor units — to `msg.sender` and emits `Transfer(address(0), msg.sender, INITIAL_SUPPLY)`.
At launch `msg.sender` is the ProjectFactory, which is the only address the launch policy can check.

After that constructor the contract is final: there is no mint, burn, owner, minter, pause,
initializer or upgrade path, and the runtime contains no `DELEGATECALL`, `CALLCODE` or
`SELFDESTRUCT`. `totalSupply()` can never change. Transfers move exactly the requested amount — no
fee, no rebase, no blocklist — and transfers to the zero address revert rather than silently
burning. `approve` uses plain overwrite semantics and rejects the zero spender; `transferFrom`
always decrements the allowance, including `type(uint256).max`, so the accounting has no exception
in it.

## TimeoutEscrow

One constructor argument, the token address, stored `immutable`. No fee, owner, admin, pause,
upgrade path or privileged role of any kind, and no external call other than `transfer` /
`transferFrom` on that one token. Every state change emits an event.

### Lifecycle

```
open(seller, amount, deadline)     -> Open      (buyer funds the escrow)
  |-- release(id)   any time,        buyer      -> Released  seller receives amount
  |-- dispute(id)   t <  deadline,   buyer      -> Disputed  buyer amount/2, seller the rest
  `-- claim(id)     t >= deadline,   seller     -> Claimed   seller receives amount
```

`Released`, `Claimed` and `Disputed` are terminal: an escrow settles exactly once, and every later
call on it reverts with `EscrowNotOpen`.

**Entry conditions (`open`).** `seller` must be neither the zero address nor the caller, `amount`
must be non-zero, and `deadline` must be strictly greater than `block.timestamp`. The caller must
have approved this contract for `amount` first. Ids are sequential from 0; `escrowCount()` is the
number ever opened.

**Timing boundaries.** `dispute` requires `block.timestamp < deadline`; `claim` requires
`block.timestamp >= deadline`. The two windows are exact complements, so at the deadline second
itself the buyer's window is over and the seller's has begun, and there is no instant in which both
or neither is available. `release` is available to the buyer for as long as the escrow is open,
including after the deadline if the seller has not claimed yet — a buyer who wants to pay in full
late is never blocked from doing so.

**Split rounding.** A dispute pays the buyer `amount / 2` and the seller the remainder, so an odd
amount rounds the extra minor unit to the seller: the party that chose to dispute never rounds in
its own favour. For `amount == 1` the buyer receives nothing and the seller receives 1; the
zero-value leg is skipped rather than sent.

**Funds.** The contract never consults its own balance. Each payout is read from the escrow record,
so tokens sent to the contract by mistake cannot change any payout — and cannot be recovered by
anyone, including the parties. Do not send SHAKE to the escrow address directly.

### Assumptions

- **The token is SHAKE.** It is a plain, non-rebasing, non-fee ERC-20 with no transfer callbacks.
  A fee-on-transfer token would record more than actually arrived, and pairing this contract with
  one is out of scope. The token is fixed at deployment and cannot be changed afterwards.
- **Transfer results are checked.** Calls are made low-level and accept either `true` or an empty
  return; `false`, a revert, a short return, or an empty return from an address with no code all
  revert with `TokenTransferFailed`. A failed transfer can never be mistaken for a settled escrow.
- **Re-entrancy is handled by ordering, not by a guard.** `release`, `dispute` and `claim` write
  the terminal status before moving any tokens, so a hostile token that calls back finds a settled
  escrow. `open` is the mirror image: it pulls the tokens *before* it assigns the id, writes the
  record or emits `EscrowOpened`, so a callback during the pull cannot act on an escrow that is not
  funded yet. (This is why the `open` event follows an external call, and why the `reentrancy-events`
  lint fires there: log ordering was traded for the stronger guarantee that no unfunded escrow is
  ever visible.) `test/TimeoutEscrow.t.sol` drives all four paths with a re-entrant token.
- **`block.timestamp` is the clock.** Deadlines are unix seconds and a validator can nudge the
  timestamp by a few seconds, which shifts the dispute/claim boundary by that much. Nothing else
  depends on time, and no randomness is derived from it. Pick deadlines with a margin far larger
  than block-time jitter — hours or days, not seconds.
- **There is no arbitrator and no refund path.** A buyer who neither releases nor disputes before
  the deadline gives the seller the whole amount; a buyer who disputes gives up half no matter who
  was right. Only the buyer may dispute, because the rule this implements — "if the buyer neither
  releases nor disputes by the deadline the seller claims" — makes the dispute the buyer's half of
  that choice. A seller who wants less than the full amount must settle off-chain.
- **Counterparty risk is real and unmitigated.** This is a timeout escrow, not an arbitrated one.
  Both parties should agree the deadline before the escrow is opened.

## Deployment

Sepolia, chain id 11155111, through ProjectFactory, per the approved launch policy.

- `Handshake` is the launch token: no constructor arguments, 18 decimals, 10^27 minor units minted
  to the deployer.
- `TimeoutEscrow` is the single application contract. Its one constructor argument is the token
  address and must be passed as the manifest reference `$token`, so it resolves to the launch token
  that the same launch deployed. It has no owner parameter, so no `$owner` appears anywhere.
- Dependency order matters: the token is deployed first, the escrow second.
- Both constructors are nonpayable and take only supported types (none, and one `address`). No
  dynamic arguments, no proxies, no `DELEGATECALL` / `CALLCODE` / `SELFDESTRUCT`, no post-deployment
  initialization call — `TimeoutEscrow` is fully configured by its constructor.
- `foundry.toml` pins `solc 0.8.26`, `evm_version = "cancun"`, `bytecode_hash = "none"`,
  `optimizer = true` with 200 runs, and leaves `ffi` off and `fs_permissions` empty.

`launch.json` is written by the separate manifest assignment; this assignment does not create it.
The pool parameters (pairing, fee, tick spacing, initial price) are policy, not a claim about value.

**This assignment produced source, tests, and ABI exports only.** No key was touched and no
transaction was broadcast or prepared for broadcast. There is no deployment script in this
repository on purpose: the admitted release runs through the deployer under the launch policy.

## Operational responsibilities

- **Before deployment:** an independent adversarial review of these contracts together with the
  manifest, in particular the `$token` argument, the dependency order, the settlement accounting
  and the timing boundaries. A passing test suite is not a security audit.
- **After deployment:** publish the deployed addresses and these ABIs to the site's
  `dist/imd-deployment.json`; the front end reads its configuration and ABIs from there. Verify the
  source on the explorer so both contracts are readable.
- **Users hold their own risk.** There is no admin to pause, refund, recover mis-sent tokens, or
  reverse a settled escrow. Nobody can rescue an escrow opened against the wrong seller — the buyer
  can only release it or wait, and a wrong seller address means the funds are that address's.
- **Front end:** approve exactly what an escrow needs rather than an unbounded allowance, show the
  deadline in the user's local time alongside the raw unix value, and disable `dispute` at or past
  the deadline and `claim` before it, so a user never sends a transaction that can only revert.
  Escrows can be listed from `escrowCount()` + `getEscrows(start, count)`, or from the
  `EscrowOpened` logs, whose `buyer` and `seller` are both indexed.

### Unresolved choices left to the manifest and the deployer

- The manifest identifier for the application contract (`TimeoutEscrow` here) and the launch token
  entry are the manifest assignment's to write.
- Nothing in this repository fixes a deadline policy, a minimum escrow amount or a UI default
  duration; those are front-end choices.

## Building and testing

Everything is vendored: `lib/forge-std` is committed as ordinary files, there is no submodule and
no dependency to fetch, and `foundry.toml` sets `offline = true`.

```sh
forge build
forge test
forge fmt --check
```

The suite is 71 tests over both contracts: launch-shape checks on the token (supply, decimals,
mint-to-deployer, absence of admin selectors, no forbidden opcodes), full success and failure
coverage of every escrow transition (wrong caller, wrong state, double settlement, unknown id,
zero and odd amounts, `deadline - 1`, `deadline`, `deadline + 1`), hostile-token paths
(re-entrancy into `release`, `dispute`, `claim` and `open`, `false` returns, reverting transfers,
empty returns, a token address with no code), and fuzz tests for conservation of funds and for the
contract's balance always equalling the sum of the escrows still open.

To regenerate the ABI exports after a source change:

```sh
forge inspect Handshake abi --json | python3 -m json.tool --indent 2 > docs/abi/Handshake.json
forge inspect TimeoutEscrow abi --json | python3 -m json.tool --indent 2 > docs/abi/TimeoutEscrow.json
```
