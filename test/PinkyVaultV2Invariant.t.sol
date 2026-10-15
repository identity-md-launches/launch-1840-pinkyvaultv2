// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {PinkyVaultV2} from "../src/PinkyVaultV2.sol";
import {PinkyStaking} from "../src/PinkyStaking.sol";
import {MockERC20, MockIntake} from "./mocks/Mocks.sol";
import {RefusingSink} from "./mocks/MocksV2.sol";

/// @dev Drives the second vault through every path in any order: four kinds of promise, with and
/// without a beneficiary, settled or closed and asked, answered on any of their live requests or
/// reported failed, paid out, refunded, with the owner's settings moving behind their delay, the
/// Intake's price moving, stakers coming and going and fees sent to whichever sink is set. A call
/// whose precondition does not hold returns early, so the fuzzer spends its depth on calls that
/// move state. Where the vault must refuse, the refusal is probed, not skipped.
contract PinkyV2Handler is Test {
    uint256 constant SIGNER_PK = 0xA11CE;
    uint256 constant NEXT_PK = 0xB0B;
    uint256 constant PRICE = 0.5 ether;
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");

    struct Req {
        address intake;
        bytes32 id;
    }

    PinkyVaultV2 public vault;
    PinkyStaking public staking;
    PinkyStaking public otherSink;
    RefusingSink public refusing;
    MockERC20 public imd;
    MockERC20 public pinky;
    MockERC20 public token;
    MockIntake public intake;
    /// @dev A second Intake the owner may switch to, so the cap on another protocol is exercised.
    MockIntake public other;

    address[3] makers = [address(0xA1), address(0xA2), address(0xA3)];
    address public friend = address(0xF4E);
    address public watcher = address(0xA5CE4);
    address staker = address(0x57A4E);
    uint256 nonce;

    uint256 public deposited;
    uint256 public toIntake;
    uint256 public toMakers;
    uint256 public toBeneficiaries;
    uint256 public toAskers;
    uint256 public toStakers;
    uint256 public burned;
    uint256 public feesSent;
    uint256 public verdicts;
    uint256 public refunds;

    mapping(uint256 => PinkyVaultV2.Status) public lastStatus;
    mapping(uint256 => bool) public lastPaid;
    mapping(uint256 => uint8) public lastAttempts;
    mapping(uint256 => uint256) public bondAt;
    mapping(uint256 => uint256) public feesPaid;
    /// @dev Every request a promise paid for, and which of them the Intake has reported failed.
    mapping(uint256 => Req[]) requests;
    mapping(bytes32 => bool) public dead;
    /// @dev The private key behind each signer the vault may hold.
    mapping(address => uint256) keyOf;

    /// @dev Called at the end of every action: a promise only moves forward, and a settled one
    /// never reopens.
    modifier steps() {
        _;
        _track();
    }

    function _track() internal {
        for (uint256 id = 1; id <= vault.count(); ++id) {
            (,,, PinkyVaultV2.Status now_, uint8 attempts, bool paid,,,,,,,,,,,,,,) = vault.promises(id);
            PinkyVaultV2.Status was = lastStatus[id];
            if (now_ != was) {
                if (was == PinkyVaultV2.Status.Active) {
                    assertTrue(now_ == PinkyVaultV2.Status.Closed, "Active only closes: no call both closes and asks");
                } else if (was == PinkyVaultV2.Status.Closed) {
                    assertTrue(
                        now_ == PinkyVaultV2.Status.Asked || now_ == PinkyVaultV2.Status.Refunded,
                        "Closed is asked or refunded"
                    );
                } else if (was == PinkyVaultV2.Status.Asked) {
                    assertTrue(
                        now_ == PinkyVaultV2.Status.Kept || now_ == PinkyVaultV2.Status.Broken
                            || now_ == PinkyVaultV2.Status.Refunded,
                        "Asked ends in a verdict or a refund"
                    );
                } else {
                    assertTrue(false, "a settled promise changed status");
                }
            }
            if (paid) {
                assertTrue(
                    now_ == PinkyVaultV2.Status.Kept || now_ == PinkyVaultV2.Status.Broken, "paid without a verdict"
                );
            }
            assertTrue(!lastPaid[id] || paid, "paid flag cleared");
            assertGe(attempts, lastAttempts[id], "attempts went down");
            assertLe(attempts - lastAttempts[id], 1, "attempts jumped");
            lastStatus[id] = now_;
            lastPaid[id] = paid;
            lastAttempts[id] = attempts;
        }
    }

    constructor(
        PinkyVaultV2 vault_,
        PinkyStaking staking_,
        MockERC20 imd_,
        MockERC20 pinky_,
        MockERC20 token_,
        MockIntake intake_
    ) {
        (vault, staking, imd, pinky, token, intake) = (vault_, staking_, imd_, pinky_, token_, intake_);
        other = new MockIntake(address(0xFEE), PRICE);
        otherSink = new PinkyStaking(address(pinky), address(imd));
        refusing = new RefusingSink();
        keyOf[vm.addr(SIGNER_PK)] = SIGNER_PK;
        keyOf[vm.addr(NEXT_PK)] = NEXT_PK;
        pinky.mint(staker, 1_000 ether);
        vm.prank(staker);
        pinky.approve(address(staking), type(uint256).max);
    }

    // ───────────────────────── reading ─────────────────────────

    function requestCount(uint256 id) external view returns (uint256) {
        return requests[id].length;
    }

    function _pick(uint256 seed) internal view returns (uint256 id) {
        uint256 n = vault.count();
        return n == 0 ? 0 : bound(seed, 1, n);
    }

    function _status(uint256 id) internal view returns (PinkyVaultV2.Status s) {
        (,,, s,,,,,,,,,,,,,,,,) = vault.promises(id);
    }

    function _maker(uint256 id) internal view returns (address m) {
        (m,,,,,,,,,,,,,,,,,,,) = vault.promises(id);
    }

    function _bond(uint256 id) internal view returns (uint256 b) {
        (,,,,,,,,, b,,,,,,,,,,) = vault.promises(id);
    }

    function _asker(uint256 id) internal view returns (address a) {
        (,,,,,,,,,,,,,,, a,,,,) = vault.promises(id);
    }

    function _current() internal view returns (MockIntake) {
        return MockIntake(address(vault.intake()));
    }

    // ───────────────────────── the world around the vault ─────────────────────────

    function pass(uint256 secs, uint256 blocks) external steps {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 3 days));
        vm.roll(vm.getBlockNumber() + bound(blocks, 1, 100_000));
    }

    /// @dev The Intake moves its price, sometimes to nothing.
    function setPrice(bool which, uint256 price) external steps {
        price = bound(price, 0, 5 ether);
        if (price < 0.05 ether) price = 0;
        (which ? other : intake).setPrice(price);
    }

    function toggleStake(uint256 amount) external steps {
        vm.startPrank(staker);
        if (staking.balanceOf(staker) == 0) staking.stake(bound(amount, 1, 1_000 ether));
        else staking.unstake(staking.balanceOf(staker));
        vm.stopPrank();
    }

    /// @dev The owner moves the oracle to the other Intake, through the seven-day delay.
    function switchProtocol(bool toOther) external steps {
        address next = address(toOther ? other : intake);
        address before = address(vault.intake());
        vm.prank(vault.owner());
        vault.proposeProtocol(next, ACTION);
        assertEq(address(vault.intake()), before, "a proposal changes nothing yet");
        vm.warp(vm.getBlockTimestamp() + vault.SETTINGS_DELAY());
        vault.enact(PinkyVaultV2.Setting.Protocol);
        assertEq(address(vault.intake()), next);
    }

    function changePanel(uint256 panel, uint256 quorum) external steps {
        panel = bound(panel, 2, 12);
        quorum = bound(quorum, 2, panel);
        vm.prank(vault.owner());
        vault.proposePanel(uint16(panel), uint16(quorum), 3_600);
        vm.warp(vm.getBlockTimestamp() + vault.SETTINGS_DELAY());
        vault.enact(PinkyVaultV2.Setting.Panel);
        assertEq(vault.panelSize(), panel);
        assertEq(vault.quorum(), quorum);
    }

    function changeSink(uint256 which) external steps {
        which = bound(which, 0, 2);
        address next = which == 0 ? address(staking) : which == 1 ? address(otherSink) : address(refusing);
        vm.prank(vault.owner());
        vault.proposeFeeSink(next);
        vm.warp(vm.getBlockTimestamp() + vault.SETTINGS_DELAY());
        vault.enact(PinkyVaultV2.Setting.FeeSink);
        assertEq(address(vault.feeSink()), next);
    }

    /// @dev A proposal the owner withdraws, or that nobody enacts yet, changes nothing.
    function proposeAndCancel(bool cancelIt) external steps {
        address before = vault.oracleSigner();
        vm.startPrank(vault.owner());
        vault.proposeSigner(address(0xBAD));
        if (cancelIt) vault.cancel(PinkyVaultV2.Setting.Signer);
        vm.stopPrank();
        if (!cancelIt) {
            vm.expectRevert(PinkyVaultV2.TooEarly.selector);
            vault.enact(PinkyVaultV2.Setting.Signer);
            vm.prank(vault.owner());
            vault.cancel(PinkyVaultV2.Setting.Signer);
        }
        assertEq(vault.oracleSigner(), before, "the signer never moves without a delay");
        (,, uint64 eta) = vault.pending(PinkyVaultV2.Setting.Signer);
        assertEq(eta, 0);
    }

    /// @dev The owner rotates the oracle's key between two, through the seven-day delay.
    function rotateSigner() external steps {
        address next = vault.oracleSigner() == vm.addr(SIGNER_PK) ? vm.addr(NEXT_PK) : vm.addr(SIGNER_PK);
        vm.prank(vault.owner());
        vault.proposeSigner(next);
        vm.warp(vm.getBlockTimestamp() + vault.SETTINGS_DELAY());
        vault.enact(PinkyVaultV2.Setting.Signer);
        assertEq(vault.oracleSigner(), next);
    }

    // ───────────────────────── promises ─────────────────────────

    function make(uint256 who, uint8 kindRaw, bool toFriend, bool aboutImd, uint256 bond, uint256 amount, uint256 dur)
        external
        steps
    {
        address maker = makers[who % 3];
        PinkyVaultV2.Kind kind = PinkyVaultV2.Kind(bound(kindRaw, 0, 3));
        uint256 price = _current().price();
        uint256 floor_ = 3 * price > vault.minBond() ? 3 * price : vault.minBond();
        bond = bound(bond, floor_, 50 ether);
        dur = bound(dur, vault.MIN_DURATION(), vault.MAX_DURATION());
        amount = bound(amount, kind == PinkyVaultV2.Kind.Keep || kind == PinkyVaultV2.Kind.Moves ? 0 : 1, 1e24);
        address target = kind == PinkyVaultV2.Kind.Pay ? friend : address(0);
        address beneficiary = toFriend ? friend : address(0);
        address about = aboutImd ? address(imd) : address(token);

        if (price == 0) {
            // Refused before any IMD is pulled, so no balance is needed to probe it. The shape is
            // checked first, so probe the price with a shape the vault accepts.
            if (kind == PinkyVaultV2.Kind.Keep || kind == PinkyVaultV2.Kind.Moves) about = address(token);
            vm.prank(maker);
            vm.expectRevert(PinkyVaultV2.InvalidPayment.selector);
            vault.make(kind, about, amount, target, beneficiary, dur, bond);
            return;
        }
        imd.mint(maker, bond);
        vm.startPrank(maker);
        imd.approve(address(vault), bond);
        if (aboutImd && (kind == PinkyVaultV2.Kind.Keep || kind == PinkyVaultV2.Kind.Moves)) {
            // The bond itself leaves as IMD inside the window: refused.
            vm.expectRevert(PinkyVaultV2.InvalidPromise.selector);
            vault.make(kind, about, amount, target, beneficiary, dur, bond);
            about = address(token);
        }
        uint256 id = vault.make(kind, about, amount, target, beneficiary, dur, bond);
        vm.stopPrank();
        deposited += bond;
        bondAt[id] = bond;
        (uint256 maxPrice, uint16 panel, uint16 quorum, address madeUnder, bytes32 action, address signerAt) =
            vault.terms(id);
        assertEq(signerAt, address(0), "no signer until the first ask");
        assertEq(maxPrice, price, "the price seen at make is the cap elsewhere");
        assertEq(madeUnder, address(_current()));
        assertEq(action, ACTION);
        assertEq(panel, 0, "no panel until the first ask");
        assertEq(quorum, 0);
        assertEq(_bond(id), bond);
    }

    function _who(uint256 id, uint8 whoRaw) internal view returns (address) {
        uint256 w = whoRaw % 3;
        return w == 0 ? _maker(id) : w == 1 ? friend : watcher;
    }

    /// @dev Closes an active promise as `who`, by `close` or by `settle`: the maker from the
    /// deadline, anyone else two minutes later. A call before that is probed and refused.
    function _close(uint256 id, address who, bool viaSettle) internal {
        (,,,,,,,,,, uint64 startBlock,, uint64 endTime,,,,,,,) = vault.promises(id);
        uint256 due = uint256(endTime) + (who == _maker(id) ? 0 : vault.CLOSE_GRACE());
        if (vm.getBlockTimestamp() < due) {
            vm.prank(who);
            vm.expectRevert(PinkyVaultV2.TooEarly.selector);
            if (viaSettle) vault.settle(id);
            else vault.close(id);
            vm.warp(due);
        }
        uint256 held = imd.balanceOf(address(vault));
        vm.prank(who);
        if (viaSettle) assertEq(vault.settle(id), bytes32(0), "a settle that closes asks nothing");
        else vault.close(id);
        assertEq(imd.balanceOf(address(vault)), held, "closing moves no funds");
        (,,,, uint8 attempts,,,,,,, uint64 endBlock,, uint64 closedAt,,,,,,) = vault.promises(id);
        assertEq(endBlock, vm.getBlockNumber(), "the window ends at the closing block");
        assertGe(endBlock, startBlock, "the window never ends before it starts");
        assertEq(closedAt, vm.getBlockTimestamp());
        assertEq(attempts, 0);
    }

    function close(uint256 seed, uint8 whoRaw) external steps {
        uint256 id = _pick(seed);
        if (id == 0) return;
        if (_status(id) != PinkyVaultV2.Status.Active) {
            vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
            vault.close(id);
            return;
        }
        _close(id, _who(id, whoRaw), false);
    }

    /// @dev Whether the current Intake can be paid for this promise, and what it costs.
    function _quote(uint256 id) internal view returns (bool payable_, uint256 price, bool same) {
        MockIntake cur = _current();
        price = cur.price();
        (uint256 maxPrice,,, address madeUnder, bytes32 action,) = vault.terms(id);
        same = address(cur) == madeUnder && action == vault.action();
        payable_ = !(price == 0 || price > _bond(id) || (!same && price > maxPrice));
    }

    /// @dev `settle` closes an active promise, asks for a closed one, and refuses the rest.
    function settle(uint256 seed, uint8 whoRaw) external steps {
        uint256 id = _pick(seed);
        if (id == 0) return;
        address who = _who(id, whoRaw);
        PinkyVaultV2.Status s = _status(id);
        if (s == PinkyVaultV2.Status.Active) {
            _close(id, who, true);
        } else if (s == PinkyVaultV2.Status.Closed) {
            _ask(id, who, true);
        } else {
            vm.prank(who);
            vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
            vault.settle(id);
        }
    }

    function ask(uint256 seed, uint8 whoRaw) external steps {
        uint256 id = _pick(seed);
        if (id == 0) return;
        address who = _who(id, whoRaw);
        PinkyVaultV2.Status s = _status(id);
        if (s != PinkyVaultV2.Status.Closed && s != PinkyVaultV2.Status.Asked) {
            vm.prank(who);
            vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
            vault.ask(id);
            return;
        }
        _ask(id, who, false);
    }

    /// @dev Asks as `who`, through `settle` (closed only) or `ask`. Every refusal the vault owes
    /// is probed first, in the order the vault checks them, and spends nothing.
    function _ask(uint256 id, address who, bool viaSettle) internal {
        PinkyVaultV2.Status s = _status(id);
        (
            ,,,,
            uint8 attempts,,,,
            address beneficiary,,,
            uint64 endBlock,,
            uint64 closedAt,
            uint64 askedAt,,,,,
            bool failed
        ) = vault.promises(id);
        uint256 held = imd.balanceOf(address(vault));
        if (s == PinkyVaultV2.Status.Asked && !failed && vm.getBlockTimestamp() < askedAt + vault.ANSWER_TIMEOUT()) {
            _refuse(id, who, viaSettle, PinkyVaultV2.TooEarly.selector);
            return;
        }
        uint256 deep = uint256(endBlock) + vault.SETTLE_DELAY_BLOCKS();
        if (vm.getBlockNumber() < deep) {
            _refuse(id, who, viaSettle, PinkyVaultV2.TooEarly.selector);
            vm.roll(deep);
        }
        if (attempts >= vault.MAX_ATTEMPTS()) {
            _refuse(id, who, viaSettle, PinkyVaultV2.NoAttemptsLeft.selector);
            return;
        }
        if (vm.getBlockTimestamp() >= closedAt + vault.REFUND_GRACE() && who != _maker(id) && who != beneficiary) {
            _refuse(id, who, viaSettle, PinkyVaultV2.NotAParty.selector);
            return;
        }
        (bool payable_, uint256 price,) = _quote(id);
        if (!payable_) {
            _refuse(id, who, viaSettle, PinkyVaultV2.InvalidPayment.selector);
            return;
        }
        assertEq(imd.balanceOf(address(vault)), held);
        address askerBefore = _asker(id);
        vm.prank(who);
        bytes32 requestId = viaSettle ? vault.settle(id) : vault.ask(id);
        _recordAsk(id, who, price, requestId, askerBefore);
    }

    function _refuse(uint256 id, address who, bool viaSettle, bytes4 err) internal {
        uint256 held = imd.balanceOf(address(vault));
        uint8 attempts = lastAttempts[id];
        PinkyVaultV2.Status s = _status(id);
        vm.prank(who);
        vm.expectRevert(err);
        if (viaSettle) vault.settle(id);
        else vault.ask(id);
        assertEq(imd.balanceOf(address(vault)), held, "a refused ask spends nothing");
        assertEq(uint8(_status(id)), uint8(s));
        (,,,, uint8 after_,,,,,,,,,,,,,,,) = vault.promises(id);
        assertEq(after_, attempts);
    }

    function _recordAsk(uint256 id, address who, uint256 price, bytes32 requestId, address askerBefore) internal {
        toIntake += price;
        feesPaid[id] += price;
        address cur = address(_current());
        requests[id].push(Req(cur, requestId));
        assertEq(vault.promiseIdFor(cur, requestId), id, "the request is the promise's");
        (,,, PinkyVaultV2.Status s,,,,,,,,,,,, address askerAfter, address askedIntake, bytes32 latest,, bool failed) =
            vault.promises(id);
        assertEq(uint8(s), uint8(PinkyVaultV2.Status.Asked));
        assertEq(askedIntake, cur);
        assertEq(latest, requestId);
        assertFalse(failed, "a fresh ask forgets the last failure");
        if (askerBefore == address(0) || askerBefore == _maker(id)) {
            assertEq(askerAfter, who, "the first asker, or the first watcher after a maker, is recorded");
        } else {
            assertEq(askerAfter, askerBefore, "a re-ask never replaces a watcher");
        }
        (, uint16 panel, uint16 quorum,,,) = vault.terms(id);
        assertLe(panel, vault.panelSize(), "the terms keep the smallest panel paid for");
        (,,,,, address boughtUnder) = vault.terms(id);
        assertEq(boughtUnder, vault.oracleSigner(), "a request is bought under the key current at its ask");
        assertLe(quorum, vault.quorum());
        assertGe(panel, 2);
        assertGe(quorum, 2);
    }

    /// @dev Picks one of the promise's requests that was not reported failed.
    function _liveRequest(uint256 id, uint256 seed) internal view returns (Req memory r, bool found) {
        uint256 n = requests[id].length;
        if (n == 0) return (r, false);
        uint256 start = bound(seed, 0, n - 1);
        for (uint256 i; i < n; ++i) {
            r = requests[id][(start + i) % n];
            if (!dead[r.id]) return (r, true);
        }
        return (r, false);
    }

    function _attest(uint256 id, uint256 out) internal returns (OracleAttestation.Attestation memory a, bool kept) {
        (,, PinkyVaultV2.Kind kind,,,, uint256 amount,,,, uint64 startBlock, uint64 endBlock,,,,,,,,) =
            vault.promises(id);
        a.requestId = bytes32(bytes16(keccak256(abi.encode(++nonce))));
        a.chainId = block.chainid;
        a.questionHash = keccak256("q");
        if (kind == PinkyVaultV2.Kind.Hold) {
            kept = out >= amount;
            a.answerType = OracleAttestation.ANSWER_BOOL;
            a.answer = abi.encode(kept);
        } else {
            kept = kind == PinkyVaultV2.Kind.Pay ? out >= amount : out <= amount;
            a.answerType = OracleAttestation.ANSWER_UINT256;
            a.answer = abi.encode(out);
        }
        a.figure = out;
        a.fromBlock = startBlock;
        a.toBlock = endBlock;
        a.blockHash = keccak256("b");
        a.panelJobId = keccak256("p");
        (, uint16 panel, uint16 quorum,,,) = vault.terms(id);
        a.panelSize = panel;
        a.quorum = quorum;
        a.agreed = panel;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + vault.validForSeconds());
    }

    function _sign(OracleAttestation.Attestation memory a, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, vault.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The oracle answers one of the promise's live requests, not always the latest.
    function answer(uint256 seed, uint256 reqSeed, uint256 out, bool byCurrent) external steps {
        uint256 id = _pick(seed);
        if (id == 0 || _status(id) != PinkyVaultV2.Status.Asked) return;
        _answer(id, reqSeed, out, byCurrent);
    }

    /// @dev Takes one promise as far as it will go in one action: closed, asked, answered and paid
    /// out, each step by the same rules as the separate actions. Without it, random sequences
    /// spread over many promises rarely carry one to a payout.
    function advance(uint256 seed, uint8 whoRaw, uint256 out, bool byCurrent) external steps {
        uint256 id = _pick(seed);
        if (id == 0) return;
        address who = _who(id, whoRaw);
        for (uint256 i; i < 4; ++i) {
            PinkyVaultV2.Status s = _status(id);
            if (s == PinkyVaultV2.Status.Active) {
                _close(id, who, false);
            } else if (s == PinkyVaultV2.Status.Closed) {
                _ask(id, who, true);
            } else if (s == PinkyVaultV2.Status.Asked) {
                _answer(id, out, out, byCurrent);
            } else {
                (,,,,, bool paid,,,,,,,,,,,,,,) = vault.promises(id);
                if (!paid && s != PinkyVaultV2.Status.Refunded) _payout(id);
                return;
            }
            if (_status(id) == s) return;
            // Each step is checked as its own action would be.
            _track();
        }
    }

    function _answer(uint256 id, uint256 reqSeed, uint256 out, bool byCurrent) internal {
        (Req memory r, bool found) = _liveRequest(id, reqSeed);
        if (!found) return;
        assertEq(vault.promiseIdFor(r.intake, r.id), id, "a live request is still the promise's");
        (,,,,,, uint256 amount,,,,,,,,,,,,,) = vault.promises(id);
        out = bound(out, 0, amount + 1);
        (OracleAttestation.Attestation memory a, bool kept) = _attest(id, out);
        uint256 held = imd.balanceOf(address(vault));
        // The key the latest ask was bought under and the current key are both taken; no other is.
        (,,,,, address boughtUnder) = vault.terms(id);
        bytes memory stranger = _sign(a, 0xBAD);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        MockIntake(r.intake).complete(r.id, a, stranger);
        bytes memory sig = _sign(a, keyOf[byCurrent ? vault.oracleSigner() : boughtUnder]);
        MockIntake(r.intake).complete(r.id, a, sig);
        verdicts += 1;
        assertEq(imd.balanceOf(address(vault)), held, "a verdict moves no funds");
        assertEq(uint8(_status(id)), uint8(kept ? PinkyVaultV2.Status.Kept : PinkyVaultV2.Status.Broken));
        assertEq(vault.promiseIdFor(r.intake, r.id), 0, "the answered request is forgotten");
        assertTrue(vault.consumed(a.requestId));
        (,,,,,,,,,,,,,,,,,, uint256 observed,) = vault.promises(id);
        assertEq(observed, out);
        // The same answer, presented again, is refused.
        vm.expectRevert(PinkyVaultV2.UnknownRequest.selector);
        MockIntake(r.intake).complete(r.id, a, sig);
    }

    /// @dev The Intake reports one of the promise's live requests failed: nothing moves, and only a
    /// report about the latest request unlocks asking again at once.
    function fail(uint256 seed, uint256 reqSeed, uint8 status) external steps {
        uint256 id = _pick(seed);
        if (id == 0 || _status(id) != PinkyVaultV2.Status.Asked) return;
        (Req memory r, bool found) = _liveRequest(id, reqSeed);
        if (!found) return;
        (,,,,,,,,, uint256 bondBefore,,,,,,,, bytes32 latest,, bool failedBefore) = vault.promises(id);
        uint256 held = imd.balanceOf(address(vault));
        MockIntake(r.intake).fail(r.id, status, bytes32("disagreed"));
        dead[r.id] = true;
        assertEq(imd.balanceOf(address(vault)), held, "a failure moves no funds");
        assertEq(_bond(id), bondBefore);
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Asked));
        assertEq(vault.promiseIdFor(r.intake, r.id), 0, "a failed request is forgotten");
        (,,,,,,,,,,,,,,,,,,, bool failedAfter) = vault.promises(id);
        assertEq(failedAfter, r.id == latest || failedBefore, "only the latest request's failure unlocks a re-ask");
        // Neither an answer nor a second report lands on a forgotten request.
        vm.expectRevert(PinkyVaultV2.UnknownRequest.selector);
        MockIntake(r.intake).fail(r.id, status, bytes32("disagreed"));
    }

    function payout(uint256 seed) external steps {
        uint256 id = _pick(seed);
        if (id == 0) return;
        _payout(id);
    }

    function _payout(uint256 id) internal {
        PinkyVaultV2.Status s = _status(id);
        (address maker,,,,, bool paid,,, address beneficiary, uint256 bond,,,,,, address asker,,,,) = vault.promises(id);
        if (paid || (s != PinkyVaultV2.Status.Kept && s != PinkyVaultV2.Status.Broken)) {
            vm.expectRevert(paid ? PinkyVaultV2.AlreadyPaid.selector : PinkyVaultV2.WrongStatus.selector);
            vault.payout(id);
            return;
        }
        uint256 feesBefore = vault.fees();
        uint256 makerBefore = imd.balanceOf(maker);
        uint256 friendBefore = imd.balanceOf(friend);
        uint256 askerBefore = imd.balanceOf(asker);
        uint256 stakingBefore = imd.balanceOf(address(staking));
        uint256 burnBefore = imd.balanceOf(vault.BURN());
        vault.payout(id);
        assertEq(_bond(id), 0);
        if (s == PinkyVaultV2.Status.Kept || beneficiary != address(0)) {
            uint256 fee = bond / 100;
            uint256 rest = bond - fee;
            assertEq(vault.fees() - feesBefore, fee, "one percent stays as the fee");
            if (s == PinkyVaultV2.Status.Kept) {
                assertEq(imd.balanceOf(maker) - makerBefore, rest, "a kept promise goes home less the fee");
                assertEq(imd.balanceOf(friend), friendBefore, "a kept promise pays no beneficiary");
                toMakers += rest;
            } else {
                assertEq(imd.balanceOf(friend) - friendBefore, rest, "a broken promise pays its beneficiary");
                assertEq(imd.balanceOf(maker), makerBefore);
                toBeneficiaries += rest;
            }
            assertEq(imd.balanceOf(address(staking)), stakingBefore);
            assertEq(imd.balanceOf(vault.BURN()), burnBefore);
            return;
        }
        assertEq(vault.fees(), feesBefore, "the public split takes no fee");
        assertEq(imd.balanceOf(maker), makerBefore, "a broken promise returns nothing");
        uint256 bounty = imd.balanceOf(asker) - askerBefore;
        uint256 shared = imd.balanceOf(address(staking)) - stakingBefore;
        uint256 burnt = imd.balanceOf(vault.BURN()) - burnBefore;
        assertEq(bounty, asker == maker ? 0 : bond / 10, "the bounty is a tenth, or nothing for the maker");
        assertLe(shared, (bond - bounty) / 2, "stakers get at most half the remainder");
        if (staking.totalStaked() == 0) assertEq(shared, 0, "nothing streams while nobody is staked");
        assertEq(bounty + shared + burnt, bond, "a broken bond is split without remainder");
        toAskers += bounty;
        toStakers += shared;
        burned += burnt;
    }

    function refund(uint256 seed) external steps {
        uint256 id = _pick(seed);
        if (id == 0) return;
        PinkyVaultV2.Status s = _status(id);
        (
            address maker,,,,
            uint8 attempts,,,,,
            uint256 bond,,,,
            uint64 closedAt,
            uint64 askedAt,,
            address askedIntake,
            bytes32 latest,,
        ) = vault.promises(id);
        if (s != PinkyVaultV2.Status.Closed && s != PinkyVaultV2.Status.Asked) {
            vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
            vault.refund(id);
            return;
        }
        bool early = (s == PinkyVaultV2.Status.Asked && vm.getBlockTimestamp() < askedAt + vault.ANSWER_TIMEOUT())
            || (attempts < vault.MAX_ATTEMPTS() && vm.getBlockTimestamp() < closedAt + vault.REFUND_GRACE());
        if (early) {
            vm.expectRevert(PinkyVaultV2.TooEarly.selector);
            vault.refund(id);
            return;
        }
        uint256 makerBefore = imd.balanceOf(maker);
        vault.refund(id);
        refunds += 1;
        toMakers += bond;
        assertEq(imd.balanceOf(maker) - makerBefore, bond, "a refund returns what is left, with no fee");
        assertEq(_bond(id), 0);
        if (s == PinkyVaultV2.Status.Asked) {
            assertEq(vault.promiseIdFor(askedIntake, latest), 0, "the latest request is forgotten");
        }
        for (uint256 i; i < requests[id].length; ++i) {
            dead[requests[id][i].id] = true;
        }
    }

    function sendFees() external steps {
        uint256 amount = vault.fees();
        address sink = address(vault.feeSink());
        uint256 held = imd.balanceOf(address(vault));
        uint256 sinkBefore = imd.balanceOf(sink);
        bool takes = sink != address(refusing) && PinkyStaking(sink).totalStaked() != 0
            && amount >= PinkyStaking(sink).MIN_REWARD();
        vault.sendFees();
        assertEq(imd.allowance(address(vault), sink), 0);
        if (amount != 0 && takes) {
            assertEq(vault.fees(), 0);
            assertEq(imd.balanceOf(sink) - sinkBefore, amount, "the sink takes exactly the fees");
            assertEq(imd.balanceOf(address(vault)), held - amount);
            feesSent += amount;
        } else {
            assertEq(vault.fees(), amount, "fees wait for a sink that takes them");
            assertEq(imd.balanceOf(address(vault)), held);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PinkyVaultV2InvariantTest is Test {
    PinkyVaultV2 vault;
    PinkyStaking staking;
    MockERC20 imd;
    MockIntake intake;
    PinkyV2Handler handler;

    function setUp() public {
        vm.warp(1_790_000_000);
        vm.roll(1_000);
        imd = new MockERC20("Identity.md", "IMD");
        MockERC20 pinky = new MockERC20("Pinky", "PINKY");
        MockERC20 token = new MockERC20("Meme", "MEME");
        intake = new MockIntake(address(0xFEE), 0.5 ether);
        staking = new PinkyStaking(address(pinky), address(imd));
        vault = new PinkyVaultV2(
            address(this),
            address(imd),
            address(staking),
            address(intake),
            bytes32("oracle.request@oracle-1"),
            vm.addr(0xA11CE),
            5 ether,
            7,
            5,
            86_400
        );
        handler = new PinkyV2Handler(vault, staking, imd, pinky, token, intake);
        targetContract(address(handler));
    }

    /// @notice The vault holds exactly the bonds it still owes plus the fees it has not sent.
    function invariant_VaultHoldsExactlyTheOpenBondsAndFees() public view {
        uint256 open;
        for (uint256 id = 1; id <= vault.count(); ++id) {
            (,,,,,,,,, uint256 bond,,,,,,,,,,) = vault.promises(id);
            open += bond;
        }
        assertEq(imd.balanceOf(address(vault)), open + vault.fees());
    }

    /// @notice Every IMD that entered went to the oracle, a maker, a beneficiary, an asker,
    /// stakers, the burn or the fee sink, or is still here.
    function invariant_EveryTokenIsAccountedFor() public view {
        assertEq(
            handler.deposited(),
            imd.balanceOf(address(vault)) + handler.toIntake() + handler.toMakers() + handler.toBeneficiaries()
                + handler.toAskers() + handler.toStakers() + handler.burned() + handler.feesSent()
        );
    }

    /// @notice A promise that was paid or refunded keeps no bond, and the vault leaves no allowance
    /// behind at any Intake or sink.
    function invariant_SettledPromisesAreEmptyAndNothingIsApproved() public view {
        for (uint256 id = 1; id <= vault.count(); ++id) {
            (,,, PinkyVaultV2.Status status,, bool paid,,,, uint256 bond,,,,,,,,,,) = vault.promises(id);
            if (paid || status == PinkyVaultV2.Status.Refunded) assertEq(bond, 0);
        }
        assertEq(imd.allowance(address(vault), address(staking)), 0);
        assertEq(imd.allowance(address(vault), address(handler.otherSink())), 0);
        assertEq(imd.allowance(address(vault), address(handler.refusing())), 0);
        assertEq(imd.allowance(address(vault), address(intake)), 0);
        assertEq(imd.allowance(address(vault), address(handler.other())), 0);
    }

    /// @notice Until it is settled, a bond is the deposit less the oracle fee each ask paid, no
    /// promise is asked more than three times, and attempts match the status.
    function invariant_BondIsTheDepositLessTheFeesPaid() public view {
        for (uint256 id = 1; id <= vault.count(); ++id) {
            (,,, PinkyVaultV2.Status status, uint8 attempts, bool paid,,,, uint256 bond,,,,,,,,,,) = vault.promises(id);
            assertLe(attempts, vault.MAX_ATTEMPTS());
            if (!paid && status != PinkyVaultV2.Status.Refunded) {
                assertEq(bond, handler.bondAt(id) - handler.feesPaid(id));
            }
            assertLe(handler.feesPaid(id), handler.bondAt(id), "fees never exceed the deposit");
            assertEq(attempts, handler.requestCount(id), "one request per attempt");
            if (status == PinkyVaultV2.Status.Active || status == PinkyVaultV2.Status.Closed) assertEq(attempts, 0);
            if (
                status == PinkyVaultV2.Status.Asked || status == PinkyVaultV2.Status.Kept
                    || status == PinkyVaultV2.Status.Broken
            ) assertGe(attempts, 1);
        }
    }

    /// @notice A promise never goes backwards: the handler checks each transition, and the count
    /// of promises with a verdict or a refund equals the verdicts delivered and refunds paid.
    function invariant_VerdictsAndRefundsAreFinal() public view {
        uint256 settled;
        uint256 refunded;
        for (uint256 id = 1; id <= vault.count(); ++id) {
            (,,, PinkyVaultV2.Status status,,,,,,,,,,,, address asker,,,,) = vault.promises(id);
            if (status == PinkyVaultV2.Status.Kept || status == PinkyVaultV2.Status.Broken) {
                settled += 1;
                assertTrue(asker != address(0), "a verdict without an asker");
            }
            if (status == PinkyVaultV2.Status.Refunded) refunded += 1;
            assertEq(uint8(status), uint8(handler.lastStatus(id)), "the handler's view is current");
        }
        assertEq(settled, handler.verdicts());
        assertEq(refunded, handler.refunds());
    }

    /// @notice What `make` refused stays refused: the shape of every promise is sound.
    function invariant_EveryPromiseIsWellFormed() public view {
        for (uint256 id = 1; id <= vault.count(); ++id) {
            (
                address maker,
                address token,
                PinkyVaultV2.Kind kind,,,,
                uint256 amount,
                address target,
                address beneficiary,,
                uint64 startBlock,
                uint64 endBlock,,,,,,,,
            ) = vault.promises(id);
            assertTrue(maker != address(0));
            assertTrue(token.code.length != 0);
            assertTrue(beneficiary != maker && beneficiary != address(vault));
            if (kind == PinkyVaultV2.Kind.Pay) {
                assertTrue(target != address(0) && target != maker && target != address(vault) && amount != 0);
            } else {
                assertEq(target, address(0));
                if (kind == PinkyVaultV2.Kind.Keep || kind == PinkyVaultV2.Kind.Moves) {
                    assertTrue(token != address(imd));
                }
                if (kind == PinkyVaultV2.Kind.Hold) assertTrue(amount != 0);
            }
            if (endBlock != 0) assertGe(endBlock, startBlock);
        }
    }

    /// @notice The owner's settings are always within what the constructor would accept, and the
    /// immutable ones never move.
    function invariant_SettingsStayValid() public view {
        assertGe(vault.panelSize(), 2);
        assertLe(vault.panelSize(), 100);
        assertGe(vault.quorum(), 2);
        assertLe(vault.quorum(), vault.panelSize());
        assertGe(vault.validForSeconds(), 60);
        assertTrue(address(vault.intake()) != address(0));
        assertTrue(vault.action() != bytes32(0));
        assertTrue(address(vault.feeSink()).code.length != 0);
        assertEq(address(vault.imd()), address(imd));
        assertEq(address(vault.staking()), address(staking));
        assertEq(vault.minBond(), 5 ether);
        assertEq(vault.owner(), address(this));
    }
}
