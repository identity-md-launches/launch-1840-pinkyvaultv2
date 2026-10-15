# Adaptation notes

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
