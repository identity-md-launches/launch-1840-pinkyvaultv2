# Adaptation notes

Two launches share this repository. The second vault's launch is first; the first launch's notes
follow, kept for the record because the contracts they describe are live.

# Launch 2: PinkyVaultV2, contracts only, Robinhood Chain (chain id 4663)

The launch deploys one contract, `PinkyVaultV2`, beside the live first vault, with the constructor
arguments the requester wrote in `launch.json`: `$owner` (resolving to
`0x89d6584e733ece619c9c34f9a370e1dff5ecf8ef`, the launch's owner), the live IMD, the live
PinkyStaking from launch #1166, the Intake version 2, the action id, the oracle signer, the minimum
bond, the panel, the quorum and the validity. No token, pool or distributor is added: the brief
asks for a contracts-only launch, and PINKY and PinkyStaking are reused as they are.

## What arrived and needed no change

Checked against the evm_contracts reference and the protected floor before anything was touched:

- **Constructor.** Ten arguments of static types (`address`, `bytes32`, `uint256`, `uint16`,
  `uint32`), under the manifest's 16, nonpayable, no initializer, no proxy, no post-deployment
  call. It stores every value and calls no other contract, so it runs on the floor's empty chain;
  the Intake, the token and the staking contract are first used by `make`, `ask` and `payout`.
- **Owner.** The owner is the first constructor argument, filled by `$owner`; never `msg.sender`
  (the factory) or `tx.origin`. The owner moves no funds: it only proposes an Intake and action, a
  signer, a panel or a fee sink, each applied by anyone after seven days, and can cancel a proposal.
  IMD, PinkyStaking and the minimum bond are immutable.
- **Forbidden capabilities.** No mint, pause, freeze, blacklist or seizure of holder balances, no
  DELEGATECALL, CALLCODE or SELFDESTRUCT, no upgrade path. Every library function the contract
  calls is `internal`; `src/OracleAttestation.sol` is byte-identical to the oracle-consumer
  reference's copy.
- **Oracle protocol.** The 15-field `Attestation` struct, the consumer's own EIP-712 domain, the
  callback and failure selectors with the protocol's parameter types, `agreed >= quorum`, the panel
  and quorum checked against what the request was bought with, the request bound to the calling
  Intake and its own request id, nothing moved in either callback, and a refund path after a
  deadline. Intake version 2 is used through `requestWithFailure` as the brief asks, and the
  protocol values are constructor input and owner-settable, as the reference requires.
- **Manifest.** `launch.json` is the requester's; the manifest step owns it and nothing in it
  changed. Its ten arguments match the constructor's declaration order and types.

## Audit findings that reproduced and were fixed

Reproduced against the unchanged code in a scratch test (`test/scratch/Probe.t.sol`, deleted
before submission) before the fix.

| Finding | File | Change | Test |
| --- | --- | --- | --- |
| [low] `close` collapses the judged window to the make block when fewer than 32 chain blocks have passed since `make` | `src/PinkyVaultV2.sol` `_close` | Reproduced: with the head 20 blocks past `make`, `settle` reverted `TooEarly` but `close` succeeded and recorded `endBlock == startBlock`, a one-block window that left the whole term out. `_close` now reverts `TooEarly` until the head is at least 32 blocks past `startBlock`, as the audit proposed, so `close` and `settle` agree and the window always ends 32 blocks behind the head. No other behaviour changed; every existing test passes unchanged. The remaining limit, that the 32 blocks before `close` are never in the window, is the design's and is documented in the README. | `test/PinkyVaultV2.t.sol`: `test_CloseRefusesUntilThirtyTwoBlocksExistBehindTheHead` |

## Audit findings not changed

- **[info] Hold (`call-compare`) and Moves (`log-count`) recipes have no live attestation
  evidence.** Reproduces as stated: only the `log-sum` recipe has a recorded live answer
  (`requests/oracle-test2.body.json`), and the recipe grammar is not in any pinned read. It is not
  a defect in the Solidity and cannot be checked offline; a live request needs a funded wallet,
  which this task does not hold and must not use. Kept as the requester wrote it, since the brief
  names all four kinds. Recorded in the README as the pre-launch check: buy one Hold and one Moves
  request through the Intake before anyone bonds behind those kinds. The cost of a refusal is
  bounded by the contract (three fees, then a refund with no verdict).
- **[info] a signer or protocol proposal enacted after seven days applies to promises already
  open.** Reproduces: a promise may run 30 days and a maker cannot exit early, so a change
  proposed inside a term takes effect inside it. This is the owner role the brief asks for and the
  oracle-consumer reference requires (every protocol value owner-settable, never a constant); the
  seven-day delay is the requester's design. Not changed. The README now states the trust
  assumption in full and names the owner: the launch's `$owner`,
  `0x89d6584e733ece619c9c34f9a370e1dff5ecf8ef`.
- **[info] coverage statement.** Not a defect. Its checks were repeated here where they could be:
  the build, the project's tests, the runtime size and opcode scan on an empty chain 4663 with the
  `launch.json` arguments. Its live reads (Intake price, staking state, ArbSys) were not repeated;
  nothing in this work depends on them.

## Checks run

`forge build` and `forge test` with the project's own `foundry.toml` and the verifier's fuzz seed:
180 tests pass (the 42 second-vault tests including the new one, the first vault's unit, edge and
invariant tests, staking, the launch token and the protocol's oracle conformance vectors). A
scratch copy of the protected floor (`create2` of the built `PinkyVaultV2` with the `launch.json`
arguments on an empty chain 4663, runtime under 24,576 bytes, no DELEGATECALL / CALLCODE /
SELFDESTRUCT) passes: 18,107 bytes of runtime after the fix, owner and signer read back as given.
No transaction, key or live read was used.

# Launch 1 (#1166): PINKY, PinkyStaking and the first vault

Pinky arrived already shaped for the ProjectFactory: `LaunchToken` (Pinky / PINKY, 10^27 minor
units to `msg.sender`, no other functions), `PinkyStaking(address, address)` and
`PinkyVault(address, address, address, address, bytes32, address, uint256, uint16, uint16, uint32)`
with the owner as the first constructor argument, no initialization calls, no proxy, no
DELEGATECALL / CALLCODE / SELFDESTRUCT, and constructors that call no other contract. None of
that needed changing, and the constructor signatures are unchanged so the constructor arguments the
requester wrote in `launch.json` still apply. Every library function the contracts call is
`internal`; the one `public` function in `OracleAttestation.sol` is on the abstract consumer
contract, not the library, and `src/OracleAttestation.sol` is byte-identical to the protocol copy in
the oracle-consumer reference.

The changes below are the audit findings that reproduced, plus the launch terms.

## Audit findings that reproduced and were fixed

Each was reproduced against the unchanged code in a scratch test before the fix.

| Finding | File | Change | Test |
| --- | --- | --- | --- |
| [medium] staking strands the stream while `totalStaked == 0` | `src/PinkyStaking.sol` `updateReward`, `stake`, `_resume` | `lastUpdate` only advances while someone is staked, so the stream is paused while nobody is, and when the next staker arrives `_resume` moves the end of the stream back by the paused time, so what was left is paid over the time that was left (revised in this round, see below: the first version credited the whole idle span to the next staker at once). `notify` still refuses when nobody is staked. The up-to-604,799 wei per `notify` lost to truncation is dust and is left as is. | `test/PinkyStaking.t.sol`: `test_StreamSurvivesAPeriodWithNobodyStaked`, `test_AGapInTheMiddleOfTheStreamIsNotLostEither`, `test_AStreamThatEndedWhilePausedResumesInFull`, `test_ANotifyAfterAGapStillAccountsForEverything`, `testFuzz_NothingIsStrandedWhenTheStreamEnds` |
| [low] `setPanel` during a pending request refuses its answer | `src/PinkyVault.sol` `Terms`, `ask`, `onOracleResult`, `_body` | The panel size and quorum a request was bought with are recorded per promise in `terms[id]` at `ask` (the smallest over its asks, since every request a bond paid for stays answerable) and the attestation is checked against those, not the owner's current settings. `_body` now takes the panel it writes as parameters. | `test/PinkyVault.t.sol`: `test_ChangingThePanelDuringARequestDoesNotRefuseItsAnswer`, `test_ARequestBoughtWithASmallerPanelIsStillAnswerable` |
| [low] `agreed >= quorum` not required | `src/PinkyVault.sol` `onOracleResult` | Added `a.agreed < a.quorum` to the `InvalidAttestation` check, as the oracle-consumer reference requires. | `test/PinkyVault.t.sol`: `test_RefusesAnAnswerThePanelDidNotAgreeOn` |
| [low] the maker can ask about their own broken promise and collect the 10% bounty | `src/PinkyVault.sol` `payout`, `ask` | The bounty is zero when the asker is the maker; that share goes with the rest to stakers and the burn. `ask` records the asker only on the first ask, or replaces a maker-asker with the first watcher who re-asks, so a maker cannot ask first to deny a watcher's bounty. | `test/PinkyVault.t.sol`: `test_AMakerWhoAsksAboutTheirOwnBrokenPromiseGetsNoBounty`, `test_AMakerWhoAsksAboutTheirOwnKeptPromiseStillGetsTheBond`, `test_AMakerWhoAsksFirstYieldsTheBountyToTheWatcherWhoReasks` |
| [low] `setProtocol` can point `ask` at an intake whose price equals a bond | `src/PinkyVault.sol` `Terms`, `make`, `ask` | `make` records the Intake, the action and the price it saw in `terms[id]`; `ask` refuses, with `InvalidPayment`, a price above that one from any other Intake or action the owner has set since. The owner keeps the Intake, action, signer and panel setters the oracle-consumer reference requires, but can no longer move a bond through them. (Revised in this round, see below: the first version capped the Intake the promise was made under too, which stranded every open promise when the trusted Intake moved its price.) | `test/PinkyVault.t.sol`: `test_AskRefusesAPriceAboveTheOneTheBondWasMadeUnderAtAnotherProtocol` |
| [low] anyone can re-ask after a day, which kills a still-valid pending answer and replaces the asker | `src/PinkyVault.sol` `ask` | A re-ask no longer deletes the earlier request's `promiseIdFor` entry: every request the bond paid for stays answerable until a verdict lands, the first answer wins, and a later one is refused with `WrongStatus`. The asker is not replaced by a re-asker (see the bounty row). Re-asking stays open to anyone, so a watcher can retry when the oracle refused a request the maker will not retry; the cost is bounded by `MAX_ATTEMPTS` and documented. | `test/PinkyVault.t.sol`: `test_AskAgainAfterATimeoutAndEitherAnswerCounts` (the old `test_AskAgainAfterATimeoutAndTheOldRequestIsDead`, changed with the behaviour), `test_AThirdPartyReaskDoesNotTakeTheWatchersBounty` |

The new storage is one `mapping(uint256 => Terms) public terms` beside `promises`; the `Promise`
struct and the `promises(id)` getter are unchanged so existing readers keep working. The callback
still fits the Intake's 200,000 gas stipend from cold storage
(`test_CallbackFitsTheIntakeStipendFromColdStorage`, using `vm.cool`).

## Launch review findings (revision)

The launch's independent review reopened the work with two reproducible findings and seven
advisory ones. Each was reproduced on the accepted tree before anything changed: the reviewer's
two proofs failed on it (run from `test/scratch/`) and pass on this tree. The answers are in
`.imd-responses.json`.

| Finding | File | Change | Test |
| --- | --- | --- | --- |
| [medium] `make` accepts a promise while the Intake quotes 0, which `ask` refuses for ever | `src/PinkyVault.sol` `make` | `make` reverts `InvalidPayment` when `priceOf` returns 0, as `ask` does, so entry and settlement agree. Read from the live chain this round: the Intake quotes 0, not a revert, for the unsold `oracle-2` action, so the state is reachable exactly as the reviewer said. The launch configuration (`oracle-1` at 0.5 IMD) is unaffected. | `test/PinkyVault.t.sol`: `test_MakeRefusesAPromiseWhileTheIntakeQuotesZero`; the reviewer's proof `Proof_ada7abc3f3e3.t.sol` |
| [medium] a price rise at the Intake during a term makes every open promise unaskable | `src/PinkyVault.sol` `Terms`, `make`, `ask` | `Terms` now records the Intake and action a promise was made under. `ask` at that same Intake and action accepts any price up to what is left of the bond (`make` sized the bond for three fees); the `maxPrice` cap from the audit fix now applies only to another Intake or action the owner has set since, which is the case it was added for. The `terms(id)` getter gained two trailing fields; `promises(id)` is unchanged. | `test/PinkyVault.t.sol`: `test_APriceRiseAtTheProtocolThePromiseWasMadeUnderIsPaidFromTheBond`, `test_APriceAboveWhatIsLeftOfTheBondIsStillRefused`, `test_AskRefusesAPriceAboveTheOneTheBondWasMadeUnderAtAnotherProtocol`; the reviewer's proof `Proof_d313e09c58c7.t.sol` |
| [low] idle stream time is credited in full to the next staker at once, so a 1 wei flash stake collects it | `src/PinkyStaking.sol` `stake`, `_resume` | Judged real: it was the sharp edge of the audit fix above. The stream is now paused while nobody is staked and, when the next staker arrives, resumes from then for the time it had left, so a flash stake earns nothing and the staker who stays is paid at the stream's rate. Nothing is stranded: a stream that ran out while paused resumes in full. `test_AGapInTheMiddleOfTheStreamIsNotLostEither` changed with the behaviour (the returning staker is paid over the remaining days, not at once). | `test/PinkyStaking.t.sol`: `test_AFlashStakeDuringAPauseEarnsNothing`, `test_AStreamThatEndedWhilePausedResumesInFull`, `test_AGapInTheMiddleOfTheStreamIsNotLostEither` |
| [info] anyone can restretch the stream with a 0.01 IMD `notify` | `src/PinkyStaking.sol` `notify` | Judged real and cheap to close: a `notify` never lowers the rate. What is added plus what is left streams over seven days when that is at least the current rate; otherwise it keeps the current rate and ends sooner. Daily dust calls now leave the week's stream intact (the reviewer's scenario pays 22 IMD in the week instead of about 14.5), and a large payout still raises the rate over a fresh seven days. | `test/PinkyStaking.t.sol`: `test_ADustNotifyDoesNotSlowTheStream`, `test_ALargerNotifyStillRaisesTheRateOverSevenDays` |
| [low] the maker-earns-no-bounty rule compares addresses only | `README.md` | Reproduces, and no contract rule can tell a maker's second wallet from a watcher. The address check stays (it closes the plain path at no cost and does not hurt anyone), the README no longer claims a broken maker gets no bounty: the sure penalty is 90% of the remaining bond and the bounty is a 10% rebate to whoever asks first. The reviewer's other shapes (a delay the maker cannot pre-empt, or a fixed asker fee on both verdicts) either do not exclude a second wallet or change the economics the requester chose. | none (documentation) |

### Advisory findings not changed

- **[info] a signed chain-evidence answer with `agreed < quorum` is refused.** Reproduces and is
  kept: the oracle-consumer reference asks for `agreed >= quorum`, and the audit asked for the
  check. The launch's panel of seven with a quorum of five tolerates a split of two. Documented in
  the README as a trade-off.
- **[info] a 30-day term is a multi-million-block window the oracle may not answer.** Cannot be
  reproduced offline and a live request needs a funded wallet, which a contributor task does not
  hold. Recorded in the README as a pre-launch check with the reviewer's remedy (cap
  `MAX_DURATION` to the oracle's limit if it has one). Not changed.
- **[info] payout depends on the live IMD accepting transfers to `0x…dEaD`.** Checked this round
  against the live token at `0x5f7b…7127` on chain 4663 without a transaction: `balanceOf(dEaD)`
  is 28.1 IMD and an `eth_call` of `transfer(dEaD, 1)` from a funded holder returns true. The burn
  cannot revert there. Recorded in the README; not changed.
- **[info] the owner can forge verdicts (`setSigner`) and route up to three fees per promise
  through an Intake of their own (`setProtocol`).** A trust assumption the oracle-consumer
  reference requires (every protocol value owner-settable). Already in the README, which now also
  says the launch should state who holds the owner key. Not changed.

## Audit findings not changed

- **[info] transfers after `endTime` but before `close` are counted.** Reproduces and is the
  documented design: the window ends at the block of `close`, which anyone may call. Not changed;
  the README now says prominently that a maker should close at the deadline themselves.
- **[info] `questionHash` is not pinned.** Reproduces: the vault binds an answer to a promise by the
  Intake request id, the chain id and the exact block range, and trusts the writer's pairing. The
  oracle's canonical question document cannot be reproduced on chain from the body, so pinning it
  would need an owner-fed hash the oracle only knows after the request. Not changed; documented as
  a trust assumption in the README.
- **[info] coverage statement.** Its one actionable point, `pool.fee` not checked against the
  launch's terms, is handled below.

## Launch terms

- `launch.json`: `pool.fee` 3000 → 12500, the launch policy's 1.25%, which admission requires.
  Nothing else in the file changed; the manifest step owns it.
- `test/LaunchToken.t.sol` (new): name, symbol, decimals, the fixed 10^27 supply to the deployer,
  a plain transfer, and that nothing mints after launch, as the launch-token reference asks.
- `README.md`: the launch section (chain, pair, supply split by the factory, the pool's 1.25%
  fee, and that the token has no extra features because the brief asked for none), the changed
  bounty / re-ask / price rules, the staking stream change, and the trust assumptions above.

## Checks run

`forge build` and `forge test` with the project's own `foundry.toml`: 53 tests pass (unit, fuzz,
invariant, the protocol's oracle conformance vector), plus the reviewer's two proofs from
`test/scratch/`. A scratch copy of the protected project floor (constructors on an empty chain 4663
with the `launch.json` arguments, supply untouched, runtime under 24,576 bytes, no DELEGATECALL /
CALLCODE / SELFDESTRUCT) passes: LaunchToken 1,489 bytes, PinkyStaking 2,704 bytes, PinkyVault
12,659 bytes. Against the live chain, reads only (no transaction, no key): the Intake's `priceOf`
for `oracle-1` and `oracle-2`, and the IMD token's symbol, `balanceOf(dEaD)` and a simulated
transfer to `dEaD`.
