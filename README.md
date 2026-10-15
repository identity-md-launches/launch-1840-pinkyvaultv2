# Pinky

A promise with money behind it.

Anyone can say they won't sell. Pinky lets them prove it. A holder — a deployer, a whale, someone
paid in tokens to promote them — locks IMD behind a promise: *"my wallet will not move more than
`maxOut` of this token before the deadline."* When
time is up, the contract buys one answer from the IdentityMD oracle out of the bond — the sum of
the wallet's outgoing `Transfer` values over the exact block range — and that answer decides
where the bond goes. Keep your word and the IMD comes home. Break it and it doesn't.

Live on Robinhood Chain since 2026-10-09 — [pinkybond.fun](https://pinkybond.fun).

| | |
|---|---|
| PinkyVault | [`0x3c81384aa1ca064316576a214e2fb30969992772`](https://robinhoodchain.blockscout.com/address/0x3c81384aa1ca064316576a214e2fb30969992772) |
| PinkyStaking | [`0x17fb2067652bcf4803e937cf323a248ff6b7cba3`](https://robinhoodchain.blockscout.com/address/0x17fb2067652bcf4803e937cf323a248ff6b7cba3) |
| PINKY | [`0xb125c461c00863aacad4cc99311d2f23d4342a6f`](https://robinhoodchain.blockscout.com/address/0xb125c461c00863aacad4cc99311d2f23d4342a6f) |
| Owner | `0x89d6584e733ece619c9c34f9a370e1dff5ecf8ef` |
| IMD launch | #1166, [source as deployed](https://github.com/identity-md-launches/launch-1166-pinkystaking-pinkyvault) |

All three contracts are verified on Sourcify, creation and runtime bytecode both an exact match:
[vault](https://repo.sourcify.dev/4663/0x3c81384aa1ca064316576a214e2fb30969992772),
[staking](https://repo.sourcify.dev/4663/0x17fb2067652bcf4803e937cf323a248ff6b7cba3),
[token](https://repo.sourcify.dev/4663/0xb125c461c00863aacad4cc99311d2f23d4342a6f).

The sources here are the ones deployed. They came out of the IdentityMD swarm's audit of this
repository: an imported-code audit, four specialist audits and a judge, whose findings are fixed
and listed in `ADAPTATION.md`. 137 Foundry tests pass (unit, fuzz, invariant and the protocol's
oracle conformance vector). No third-party audit.

## How it works

1. **make** — the holder calls `PinkyVault.make(token, maxOut, duration, bond)`. The vault
   pulls `bond` IMD, which must cover three oracle fees at the Intake's current quote, and records
   the current block. While the Intake quotes no price for the configured action (it is not sold
   yet, or no longer), `make` refuses, since such a promise could never be settled.
2. **close** — once the deadline has passed, anyone calls `close(id)`, which fixes the closing
   block. **Until then the promise keeps running**: a transfer after the deadline but before
   `close` is still counted, so a maker should close at the deadline themselves rather than wait
   for a watcher to do it.
3. **ask** — 32 blocks later anyone calls `ask(id)`. The vault pays the Intake 0.5 IMD from the
   bond and sends an `oracle.request` with `evidence: "chain"` and a pinned `log-sum` recipe:
   `Transfer` events of `token`, filtered to `from = maker`, summed over `[startBlock, endBlock]`.
   The bond pays the Intake's current price for the action the promise was made under, even if it
   has risen since, up to what is left of the bond. Only another Intake or action the owner has
   set since is held to the price quoted when the promise was made.
4. **verdict** — the Intake calls `onOracleResult` with the signed attestation. The vault checks
   the signature in its own EIP-712 domain, the chain id, both block numbers, that the panel and
   quorum are at least what the request was bought with, and that at least `quorum` members
   agreed, and records `Kept` (sum ≤ `maxOut`) or `Broken`. No funds move in the callback.
5. **payout** — anyone calls `payout(id)`.
   - Kept: the rest of the bond returns to the maker.
   - Broken: 10% to the first wallet that asked, half of the remainder to PINKY stakers, the rest
     to `0x…dEaD`. When the asking wallet is the promising wallet there is no bounty and that
     share burns or goes to stakers with the rest. The contract cannot tell a maker's second
     wallet from a watcher, so the penalty a broken maker is sure to pay is 90% of the remaining
     bond, and the bounty is best read as a 10% rebate to whoever asks first.

If the oracle gives no answer, `ask` can be repeated after 24 hours, three times in all. Every
request a bond paid for stays answerable until a verdict lands, so a late answer to an earlier
request still counts, and the first watcher to ask keeps the bounty. After three failed attempts,
or seven days after closing, `refund(id)` returns what is left to the maker.

## The second vault (PinkyVaultV2, not deployed yet)

`src/PinkyVaultV2.sol` is launched beside the first vault, reusing PINKY and PinkyStaking; its
manifest is `launch.json` (the first launch's is kept in `launches/1166-launch.json`). It adds:

| | |
|---|---|
| Four kinds | **Keep**: no more than N of a token out (the first vault's promise). **Pay**: at least N of a token sent to a named address (log-sum filtered on `from` and `to`, tested live on 2026-10-14). **Hold**: at least N held at the closing block (`call-compare` on `balanceOf`, so NFTs and staked balances too; checked once, at the end). **Moves**: no more than N transfers out (`log-count`, for NFTs) |
| A beneficiary | A promise can be made to someone. Broken, the bond goes to them, less 1% |
| A fee | 1% of every bond that goes home or to a beneficiary, sent to PinkyStaking. None on the public split or a refund |
| One call to settle | `settle(id)` closes the window 32 blocks behind the head and asks at once, two minutes after the deadline |
| Intake v2 | Asks with `requestWithFailure`: a refusal or a panel that did not agree is reported at once. The report is unsigned, moves no funds and only lets anyone ask again without the day's wait |
| Slow settings | The owner can only propose a new Intake, signer, panel or fee sink; anyone applies it seven days later |

Tests: `test/PinkyVaultV2.t.sol`.

## Where IMD is used

| | |
|---|---|
| Bond | Held in IMD; the minimum is 5 IMD and never less than three oracle fees |
| Oracle | Every settlement is an on-chain `oracle.request` paid in IMD through the Intake |
| Broken promises | IMD is burned and streamed to PINKY stakers |
| Token | PINKY launches through the IMD ProjectFactory, paired with IMD |

## Contracts

| File | What it is |
|---|---|
| `src/PinkyVault.sol` | Bonds, the oracle request, the verdict and the payout |
| `src/PinkyStaking.sol` | Stake PINKY, earn forfeited IMD over a seven-day stream. No owner. The stream pauses while nobody is staked and resumes for the time it had left when the next staker arrives; a payout that lands mid-stream never slows the stream, so dust cannot stretch it |
| `src/OracleAttestation.sol` | The IdentityMD consumer library, unchanged from launch 976 |
| `src/LaunchToken.sol` | The fixed launch token |

## Build

```
forge build
forge test
```

Foundry 1.8.3, solc 0.8.26. Dependencies are vendored under `lib/` (OpenZeppelin Contracts
v5.5.0, forge-std v1.9.7); nothing is downloaded at build time.

## Trust and known limits

- **Owner.** The vault owner can change the Intake, the action id, the oracle signer and the
  panel settings. A malicious owner could point the signer at a key of their own and forge
  verdicts. The owner cannot redirect a bond through an Intake of their own: another Intake or
  action is never charged more per request than the price quoted when the promise was made, at
  most three times. A panel change applies to new requests only. IMD, the staking contract and
  the minimum bond cannot be changed. The launch should state who holds the owner key.
- **The Intake's price.** The Intake the promise was made under is trusted: if it raises the
  action's price during the term, the bond pays the new price, up to what is left of the bond.
- **Split panels.** An answer the panel did not agree on at quorum is refused, as the oracle
  consumer reference asks, even for chain evidence where the oracle's own rerun settled a split.
  Each refused answer costs a fee, and after three, or a week, the bond is refunded. The launch's
  panel of seven with a quorum of five tolerates a split of two.
- **One wallet.** A promise covers one wallet and one token. Tokens the maker holds elsewhere
  are not covered.
- **No answer favours the maker.** If the oracle cannot answer, the bond is refunded. A maker who
  could make the question unanswerable would get their bond back. Anyone may re-ask after a day;
  each re-ask costs the bond another oracle fee, three in all.
- **Answers are paired by the writer.** The vault does not pin the oracle's `questionHash`; an
  answer is bound to a promise by the Intake request id, the chain id and the exact block range.
  Two promises closed in the same blocks rely on the Intake's writer delivering each answer under
  its own request id.
- **Window length.** The longest window settled so far is promise #2 on 2026-10-11: 921,335
  blocks, a little over a day, attested in 92 seconds (oracle request
  `48323d51-a3d8-47fd-a309-b17f8358067e`). A 30-day term is tens of millions of blocks and is
  untested; if the oracle cannot answer it, the bond is refunded after three attempts.
- **Standard tokens only.** Rebasing or fee-on-transfer tokens are out of scope.
- **Not for NFTs.** The question sums the `value` of `Transfer` events. ERC-721 puts a token id
  there instead of an amount and ERC-1155 uses other events, so a promise about an NFT would be
  judged on nothing and could come back "kept" whatever the maker did. The vault itself does not
  refuse an NFT address; the site's form does.
- **Gas-limited payout.** The staker share is sent in a `try`; if it fails, that share is burned.

## Checked against the live oracle

On 2026-10-09 the exact question the vault builds was paid for on Robinhood Chain
(`0x1e725da5203496444ba7a33cb4a66bb71e82e990c9a9bf823160edc83b0e2b96`, oracle request
`c5e21f11-5172-4f9b-a506-9babcdfa47c2`). The window held four IMD transfers worth 18.6457 IMD; one,
6.2152 IMD, came from the address in the filter. The oracle attested 6215220149346698936 wei in
2 minutes 15 seconds, with the `filter.from` recipe as asked. That request used a panel of five with
a quorum of four; the launch asks for a panel of seven with a quorum of five.

That request had no callback. Delivery into the vault is covered by tests against a mock Intake
and has not run on chain yet.

Read on 2026-10-09 from the chain's RPC, without a transaction: the Intake quotes 0.5 IMD for
`oracle.request@oracle-1` and 0, not a revert, for `oracle.request@oracle-2`, which is why `make`
refuses a zero quote; and the live IMD token accepts `0x…dEaD` as a recipient (it already holds
28.1 IMD and a simulated transfer to it returns true), so a broken promise's burn cannot revert.

## Launch

PINKY launches through the IdentityMD ProjectFactory on Robinhood Chain (chain id 4663), paired
with IMD. `LaunchToken` mints the whole fixed supply of 1,000,000,000 PINKY to the factory, which
splits it: 10% to the swarm, 88% seeds the pool and 2% goes to the policy's wallet. No contract
here is sent any of it at launch; PinkyStaking only holds what stakers deposit later. The pool
opens at the network's trading fee of 1.25%. The token has no mint, owner, pause, blocklist, fee or
upgrade path, and the brief asked for none.

## Site

`site/` is the page at pinkybond.fun: static, no build step. It reads the vault in one batched call
to the public node and sends transactions through the visitor's wallet.

## The first promise, end to end

Promise #1, 2026-10-09: the owner wallet bonded 5 IMD on not moving a single PINKY for ten minutes.

| Step | Transaction |
|---|---|
| `make` | [`0xc8d8179a…5634`](https://robinhoodchain.blockscout.com/tx/0xc8d8179a4da742e614d7a2c18e687ac0a0c37309e392944184855d846f805634) |
| `close` | [`0xc5d22119…ad45`](https://robinhoodchain.blockscout.com/tx/0xc5d221197edb40f8a3c8264a375ae5f15415bf5d33415e6dc00d160a4cf0ad45) |
| `ask` | [`0xec12176c…3f7f`](https://robinhoodchain.blockscout.com/tx/0xec12176ce018b503e1764918d3b8e0542d3dc41557088cb221f97c6ea9653f7f) |
| verdict, delivered by the Intake | [`0x5933a994…c179`](https://robinhoodchain.blockscout.com/tx/0x5933a9945475b878d9c6b64ab1a9e873e958160333f8b7cb396e197208afc179) |
| `payout` | [`0xcfe0ba65…1563`](https://robinhoodchain.blockscout.com/tx/0xcfe0ba65fac77958b8fd656e402dd0d26e5ab675fe4055ea8b60bbf1d2091563) |

The oracle (request `dbcac6c2-6328-47a9-8e07-4c7b55f78e45`) summed the wallet's outgoing PINKY over
blocks 84272522–84278497 and attested 0: kept. 4.5 IMD went home, 0.5 IMD paid for the question.
The callback used 104,652 gas in all, inside the Intake's 200,000.

What this run showed: the answer took 11 minutes 18 seconds, against 2 minutes 15 for the earlier
test, so verdicts take minutes, not seconds. The oracle signs as soon as a quorum of matching
answers is in: five members answered, all five said 0, and the other two seats were not waited
for.
