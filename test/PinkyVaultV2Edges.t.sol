// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {PinkyVaultV2} from "../src/PinkyVaultV2.sol";
import {PinkyStaking} from "../src/PinkyStaking.sol";
import {MockERC20, MockIntake} from "./mocks/Mocks.sol";
import {FeeOnTransferERC20, RevertingIntake} from "./mocks/MoreMocks.sol";
import {
    StipendIntakeV2,
    RevertingIntakeV2,
    BrokenQuoteIntakeV2,
    OddPullIntakeV2,
    ShortSink,
    RefusingSink,
    DeafSink
} from "./mocks/MocksV2.sol";

/// @notice The second vault read as an adversary: the inputs its happy-path suite does not send.
/// The launch's configuration (panel 7, quorum 5, 86,400 seconds, 5 IMD minimum bond, 0.5 IMD
/// price) around a mock Intake that can deliver under the real stipend.
contract PinkyVaultV2EdgesTest is Test {
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");
    uint256 constant PRICE = 0.5 ether;
    uint256 constant MIN_BOND = 5 ether;
    uint256 constant BOND = 10 ether;
    uint256 constant AMOUNT = 1_000 ether;
    uint16 constant PANEL = 7;
    uint16 constant QUORUM = 5;
    uint32 constant VALID_FOR = 86_400;
    uint256 constant SIGNER_PK = 0xA11CE;

    MockERC20 imd;
    MockERC20 pinky;
    MockERC20 token;
    StipendIntakeV2 intake;
    PinkyStaking staking;
    PinkyVaultV2 vault;

    address owner = makeAddr("owner");
    address payee = makeAddr("payee");
    address maker = makeAddr("maker");
    address friend = makeAddr("friend");
    address watcher = makeAddr("watcher");
    address staker = makeAddr("staker");
    address signer;

    function setUp() public {
        vm.warp(1_790_000_000);
        vm.roll(1_000);
        signer = vm.addr(SIGNER_PK);
        imd = new MockERC20("Identity.md", "IMD");
        pinky = new MockERC20("Pinky", "PINKY");
        token = new MockERC20("Meme", "MEME");
        intake = new StipendIntakeV2(payee, PRICE);
        staking = new PinkyStaking(address(pinky), address(imd));
        vault = _deploy(address(intake), ACTION, signer, MIN_BOND, PANEL, QUORUM, VALID_FOR);
        imd.mint(maker, 100 ether);
        vm.prank(maker);
        imd.approve(address(vault), type(uint256).max);
    }

    // ───────────────────────── helpers ─────────────────────────

    function _deploy(
        address intake_,
        bytes32 action_,
        address signer_,
        uint256 minBond_,
        uint16 panel_,
        uint16 quorum_,
        uint32 validFor_
    ) internal returns (PinkyVaultV2) {
        return new PinkyVaultV2(
            owner, address(imd), address(staking), intake_, action_, signer_, minBond_, panel_, quorum_, validFor_
        );
    }

    function _make(PinkyVaultV2.Kind kind, address target, address beneficiary) internal returns (uint256 id) {
        vm.prank(maker);
        id = vault.make(kind, address(token), AMOUNT, target, beneficiary, 1 hours, BOND);
    }

    function _keep() internal returns (uint256) {
        return _make(PinkyVaultV2.Kind.Keep, address(0), address(0));
    }

    function _due() internal {
        vm.warp(vm.getBlockTimestamp() + 1 hours + vault.CLOSE_GRACE());
        vm.roll(vm.getBlockNumber() + 37_200);
    }

    function _settle(uint256 id) internal returns (bytes32 requestId) {
        return _settleAs(id, watcher);
    }

    /// @dev Two calls, as on chain: the first closes at the head, the second asks 32 blocks later.
    function _settleAs(uint256 id, address who) internal returns (bytes32 requestId) {
        _due();
        vm.prank(who);
        assertEq(vault.settle(id), bytes32(0), "a settle that closes asks nothing");
        _confirmed();
        vm.prank(who);
        requestId = vault.settle(id);
    }

    /// @dev The 32 blocks the oracle wants behind the closing block.
    function _confirmed() internal {
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());
    }

    /// @dev Both settle calls on any vault, by this contract, once the promise is due.
    function _settleOn(PinkyVaultV2 v, uint256 id) internal returns (bytes32 requestId) {
        assertEq(v.settle(id), bytes32(0));
        _confirmed();
        requestId = v.settle(id);
    }

    function _window(uint256 id) internal view returns (uint64 startBlock, uint64 endBlock) {
        (,,,,,,,,,, startBlock, endBlock,,,,,,,,) = vault.promises(id);
    }

    function _status(uint256 id) internal view returns (PinkyVaultV2.Status status) {
        (,,, status,,,,,,,,,,,,,,,,) = vault.promises(id);
    }

    function _bond(uint256 id) internal view returns (uint256 bond) {
        (,,,,,,,,, bond,,,,,,,,,,) = vault.promises(id);
    }

    function _attempts(uint256 id) internal view returns (uint8 attempts) {
        (,,,, attempts,,,,,,,,,,,,,,,) = vault.promises(id);
    }

    function _asker(uint256 id) internal view returns (address asker) {
        (,,,,,,,,,,,,,,, asker,,,,) = vault.promises(id);
    }

    function _attestation(uint256 id, uint8 answerType, bytes memory answer, uint256 figure)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        (uint64 startBlock, uint64 endBlock) = _window(id);
        a.requestId = bytes32(bytes16(keccak256(abi.encode(id, figure, answer, vm.getBlockTimestamp()))));
        a.chainId = block.chainid;
        a.questionHash = keccak256("q");
        a.answerType = answerType;
        a.answer = answer;
        a.figure = figure;
        a.fromBlock = startBlock;
        a.toBlock = endBlock;
        a.blockHash = keccak256("b");
        a.panelJobId = keccak256("p");
        a.panelSize = PANEL;
        a.quorum = QUORUM;
        a.agreed = PANEL;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + VALID_FOR);
    }

    function _uint(uint256 id, uint256 out) internal view returns (OracleAttestation.Attestation memory) {
        return _attestation(id, OracleAttestation.ANSWER_UINT256, abi.encode(out), out);
    }

    function _signFor(OracleAttestation.Attestation memory a, PinkyVaultV2 v, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(pk, v.attestationDigest(a));
        return abi.encodePacked(r, s, sv);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        return _signFor(a, vault, SIGNER_PK);
    }

    function _answerUint(uint256 id, bytes32 requestId, uint256 out) internal {
        OracleAttestation.Attestation memory a = _uint(id, out);
        intake.complete(requestId, a, _sign(a));
    }

    function _stake(uint256 amount) internal {
        pinky.mint(staker, amount);
        vm.startPrank(staker);
        pinky.approve(address(staking), type(uint256).max);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _enact(PinkyVaultV2.Setting setting) internal {
        vm.warp(vm.getBlockTimestamp() + vault.SETTINGS_DELAY());
        vault.enact(setting);
    }

    // ───────────────────────── constructor ─────────────────────────

    function test_ConstructorRefusesEveryZero() public {
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        new PinkyVaultV2(
            address(0), address(imd), address(staking), address(intake), ACTION, signer, MIN_BOND, 7, 5, 1 days
        );
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        new PinkyVaultV2(owner, address(0), address(staking), address(intake), ACTION, signer, MIN_BOND, 7, 5, 1 days);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        new PinkyVaultV2(owner, address(imd), address(0), address(intake), ACTION, signer, MIN_BOND, 7, 5, 1 days);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        _deploy(address(0), ACTION, signer, MIN_BOND, 7, 5, 1 days);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        _deploy(address(intake), bytes32(0), signer, MIN_BOND, 7, 5, 1 days);
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        _deploy(address(intake), ACTION, address(0), MIN_BOND, 7, 5, 1 days);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        _deploy(address(intake), ACTION, signer, 0, 7, 5, 1 days);
    }

    function test_ConstructorPanelBoundaries() public {
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        _deploy(address(intake), ACTION, signer, MIN_BOND, 1, 1, 1 days);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        _deploy(address(intake), ACTION, signer, MIN_BOND, 101, 5, 1 days);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        _deploy(address(intake), ACTION, signer, MIN_BOND, 7, 1, 1 days);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        _deploy(address(intake), ACTION, signer, MIN_BOND, 7, 8, 1 days);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        _deploy(address(intake), ACTION, signer, MIN_BOND, 7, 5, 59);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        _deploy(address(intake), ACTION, signer, MIN_BOND, 7, 5, 30 days + 1);
        // The edges themselves are accepted.
        _deploy(address(intake), ACTION, signer, 1, 2, 2, 60);
        _deploy(address(intake), ACTION, signer, MIN_BOND, 100, 100, 30 days);
    }

    /// The launch's arguments land where the manifest says, the constructor calls nothing, and
    /// the staking contract is both the public split's pool and the first fee sink.
    function test_ConstructorRecordsTheLaunchArgumentsWithoutCallingAnyone() public {
        address noCode = makeAddr("no code anywhere");
        PinkyVaultV2 bare = new PinkyVaultV2(
            owner, address(0x1111), address(0x2222), address(0x3333), ACTION, signer, MIN_BOND, PANEL, QUORUM, VALID_FOR
        );
        assertEq(bare.owner(), owner);
        assertEq(address(bare.imd()), address(0x1111));
        assertEq(address(bare.staking()), address(0x2222));
        assertEq(address(bare.feeSink()), address(0x2222), "staking is the first fee sink");
        assertEq(address(bare.intake()), address(0x3333));
        assertEq(bare.action(), ACTION);
        assertEq(bare.oracleSigner(), signer);
        assertEq(bare.minBond(), MIN_BOND);
        assertEq(bare.panelSize(), PANEL);
        assertEq(bare.quorum(), QUORUM);
        assertEq(bare.validForSeconds(), VALID_FOR);
        assertEq(bare.count(), 0);
        assertEq(bare.fees(), 0);
        (,, uint64 eta) = bare.pending(PinkyVaultV2.Setting.Protocol);
        assertEq(eta, 0);
        noCode;
    }

    // ───────────────────────── make ─────────────────────────

    function test_MakeAcceptsTheExactBoundaries() public {
        vm.startPrank(maker);
        vault.make(PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 10 minutes, MIN_BOND);
        vault.make(PinkyVaultV2.Kind.Moves, address(token), 0, address(0), address(0), 30 days, MIN_BOND);
        vault.make(PinkyVaultV2.Kind.Hold, address(token), 1, address(0), address(0), 1 hours, MIN_BOND);
        vault.make(PinkyVaultV2.Kind.Pay, address(token), 1, friend, address(0), 1 hours, MIN_BOND);
        vm.expectRevert(PinkyVaultV2.InvalidPromise.selector);
        vault.make(PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 30 days + 1, MIN_BOND);
        vm.expectRevert(PinkyVaultV2.BondTooSmall.selector);
        vault.make(PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 1 hours, MIN_BOND - 1);
        vm.stopPrank();
        assertEq(vault.count(), 4);
        // Keep and Moves may promise nothing at all: any transfer out then breaks them.
        (,,,,,, uint256 amount,,,,,,,,,,,,,) = vault.promises(1);
        assertEq(amount, 0);
    }

    function test_MakeNeedsThreeOracleFeesEvenAboveTheMinimumBond() public {
        intake.setPrice(2 ether);
        vm.startPrank(maker);
        vm.expectRevert(PinkyVaultV2.BondTooSmall.selector);
        vault.make(PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 1 hours, 6 ether - 1);
        vault.make(PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 1 hours, 6 ether);
        vm.stopPrank();
    }

    function test_MakeNeedsAnAllowanceAndABalance() public {
        address poor = makeAddr("poor");
        vm.startPrank(poor);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, BOND)
        );
        vault.make(PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 1 hours, BOND);
        imd.approve(address(vault), BOND);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 0, BOND));
        vault.make(PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 1 hours, BOND);
        vm.stopPrank();
        assertEq(vault.count(), 0);
    }

    function test_MakeRefusesAnImdThatTakesAFee() public {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20(100);
        PinkyVaultV2 odd = new PinkyVaultV2(
            owner, address(fee), address(staking), address(intake), ACTION, signer, MIN_BOND, PANEL, QUORUM, VALID_FOR
        );
        fee.mint(maker, BOND);
        vm.startPrank(maker);
        fee.approve(address(odd), BOND);
        vm.expectRevert(PinkyVaultV2.InvalidPayment.selector);
        odd.make(PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 1 hours, BOND);
        vm.stopPrank();
    }

    function test_MakeWhileTheQuoteIsBrokenReverts() public {
        BrokenQuoteIntakeV2 broken = new BrokenQuoteIntakeV2();
        PinkyVaultV2 v = _deploy(address(broken), ACTION, signer, MIN_BOND, PANEL, QUORUM, VALID_FOR);
        vm.startPrank(maker);
        imd.approve(address(v), BOND);
        vm.expectRevert("no quote");
        v.make(PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 1 hours, BOND);
        vm.stopPrank();
    }

    function test_EveryEntryPointRefusesUnknownIds() public {
        uint256 id = _keep();
        uint256[2] memory bad = [uint256(0), id + 1];
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(PinkyVaultV2.UnknownPromise.selector);
            vault.close(bad[i]);
            vm.expectRevert(PinkyVaultV2.UnknownPromise.selector);
            vault.settle(bad[i]);
            vm.expectRevert(PinkyVaultV2.UnknownPromise.selector);
            vault.ask(bad[i]);
            vm.expectRevert(PinkyVaultV2.UnknownPromise.selector);
            vault.payout(bad[i]);
            vm.expectRevert(PinkyVaultV2.UnknownPromise.selector);
            vault.refund(bad[i]);
            vm.expectRevert(PinkyVaultV2.UnknownPromise.selector);
            vault.bodyOf(bad[i]);
        }
    }

    function test_MakeEmitsMade() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit PinkyVaultV2.Made(
            1,
            maker,
            address(token),
            PinkyVaultV2.Kind.Pay,
            AMOUNT,
            friend,
            friend,
            BOND,
            1_000,
            uint64(vm.getBlockTimestamp() + 1 hours)
        );
        _make(PinkyVaultV2.Kind.Pay, friend, friend);
    }

    // ───────────────────────── the callback, from the wrong place ─────────────────────────

    function test_TheCallbackRefusesAnyoneButTheIntakeThatWasAsked() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        OracleAttestation.Attestation memory a = _uint(id, 0);
        bytes memory sig = _sign(a);
        // Not the Intake at all.
        vm.expectRevert(PinkyVaultV2.UnknownRequest.selector);
        vault.onOracleResult(requestId, a, sig);
        vm.prank(signer);
        vm.expectRevert(PinkyVaultV2.UnknownRequest.selector);
        vault.onOracleResult(requestId, a, sig);
        // Another Intake, even the one the owner switches to later, was not asked this.
        MockIntake stranger = new MockIntake(payee, PRICE);
        vm.prank(address(stranger));
        vm.expectRevert(PinkyVaultV2.UnknownRequest.selector);
        vault.onOracleResult(requestId, a, sig);
        // The Intake, about a request nobody here made.
        vm.prank(address(intake));
        vm.expectRevert(PinkyVaultV2.UnknownRequest.selector);
        vault.onOracleResult(keccak256("somebody else paid for this"), a, sig);
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Asked));
    }

    function test_AVerdictCannotBeReplayedOrReused() public {
        uint256 a1 = _keep();
        uint256 a2 = _keep();
        _due();
        vault.settle(a1);
        vault.settle(a2);
        _confirmed();
        bytes32 r1 = vault.settle(a1);
        bytes32 r2 = vault.settle(a2);
        OracleAttestation.Attestation memory a = _uint(a1, 0);
        bytes memory sig = _sign(a);
        intake.complete(r1, a, sig);
        // Again: the request is forgotten.
        vm.expectRevert(PinkyVaultV2.UnknownRequest.selector);
        intake.complete(r1, a, sig);
        // The same oracle request id, resigned for the other promise: consumed once.
        OracleAttestation.Attestation memory b = _uint(a2, 0);
        b.requestId = a.requestId;
        bytes memory sigB = _sign(b);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        intake.complete(r2, b, sigB);
        assertEq(uint8(_status(a2)), uint8(PinkyVaultV2.Status.Asked));
    }

    function test_RefusesAnExpiredOrPreSignedAttestation() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        OracleAttestation.Attestation memory a = _uint(id, 0);
        a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
        bytes memory sig = _sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        intake.complete(requestId, a, sig);
        a = _uint(id, 0);
        a.issuedAt = uint64(vm.getBlockTimestamp() + 5 minutes + 1);
        sig = _sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        intake.complete(requestId, a, sig);
        // Exactly at the edges it is still taken.
        a = _uint(id, 0);
        a.expiresAt = uint64(vm.getBlockTimestamp());
        a.issuedAt = uint64(vm.getBlockTimestamp() + 5 minutes);
        intake.complete(requestId, a, _sign(a));
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Kept));
    }

    function test_RefusesAnAnswerAboutAnotherChainOrOtherBlocks() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        OracleAttestation.Attestation memory a = _uint(id, 0);
        a.chainId = 4663;
        bytes memory sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);
        a = _uint(id, 0);
        a.fromBlock -= 1;
        sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);
        a = _uint(id, 0);
        a.toBlock -= 1;
        sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);
    }

    function test_RefusesAnInconsistentOrShortPanel() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        // Quorum above the panel.
        OracleAttestation.Attestation memory a = _uint(id, 0);
        a.panelSize = 7;
        a.quorum = 8;
        a.agreed = 8;
        bytes memory sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);
        // A quorum below what was paid for, even with the panel whole.
        a = _uint(id, 0);
        a.quorum = 4;
        a.agreed = 7;
        sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);
        // Agreement one short of the quorum.
        a = _uint(id, 0);
        a.agreed = 4;
        sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);
        // A bigger panel than paid for is fine.
        a = _uint(id, 0);
        a.panelSize = 30;
        a.quorum = 20;
        a.agreed = 20;
        intake.complete(requestId, a, _sign(a));
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Kept));
    }

    function test_RefusesAnAnswerOfTheWrongShape() public {
        uint256 keep = _keep();
        uint256 hold = _make(PinkyVaultV2.Kind.Hold, address(0), address(0));
        _due();
        vault.settle(keep);
        vault.settle(hold);
        _confirmed();
        bytes32 rk = vault.settle(keep);
        bytes32 rh = vault.settle(hold);
        // Too short, too long, empty.
        OracleAttestation.Attestation memory a = _attestation(keep, OracleAttestation.ANSWER_UINT256, new bytes(31), 0);
        bytes memory sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.InvalidAttestation.selector);
        intake.complete(rk, a, sig);
        a = _attestation(keep, OracleAttestation.ANSWER_UINT256, abi.encode(uint256(1), uint256(2)), 0);
        sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.InvalidAttestation.selector);
        intake.complete(rk, a, sig);
        a = _attestation(keep, OracleAttestation.ANSWER_UINT256, "", 0);
        sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.InvalidAttestation.selector);
        intake.complete(rk, a, sig);
        // A bool that is neither true nor false.
        a = _attestation(hold, OracleAttestation.ANSWER_BOOL, abi.encode(uint256(2)), 2);
        sig = _sign(a);
        vm.expectRevert();
        intake.complete(rh, a, sig);
        assertEq(uint8(_status(keep)), uint8(PinkyVaultV2.Status.Asked));
        assertEq(uint8(_status(hold)), uint8(PinkyVaultV2.Status.Asked));
    }

    function test_RefusesASignatureForAnotherVaultOrAMalformedOne() public {
        PinkyVaultV2 twin = _deploy(address(intake), ACTION, signer, MIN_BOND, PANEL, QUORUM, VALID_FOR);
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        OracleAttestation.Attestation memory a = _uint(id, 0);
        bytes memory forTwin = _signFor(a, twin, SIGNER_PK);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, forTwin);
        bytes memory good = _sign(a);
        bytes memory short = new bytes(64);
        for (uint256 i; i < 64; ++i) {
            short[i] = good[i];
        }
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, short);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, "");
        good[10] ^= 0x01;
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, good);
        // Tampering with any signed field after signing.
        a = _uint(id, 0);
        good = _sign(a);
        a.answer = abi.encode(AMOUNT + 1);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, good);
    }

    // ───────────────────────── under the real stipend ─────────────────────────

    /// The real Intake hands each callback 200,000 gas from cold storage; every kind must fit.
    function test_EveryVerdictLandsUnderTheStipendFromCold() public {
        uint256[4] memory ids = [
            _keep(),
            _make(PinkyVaultV2.Kind.Pay, friend, friend),
            _make(PinkyVaultV2.Kind.Hold, address(0), friend),
            _make(PinkyVaultV2.Kind.Moves, address(0), address(0))
        ];
        _due();
        for (uint256 i; i < 4; ++i) {
            bytes32 requestId = _settleOn(vault, ids[i]);
            OracleAttestation.Attestation memory a = i == 2
                ? _attestation(ids[i], OracleAttestation.ANSWER_BOOL, abi.encode(false), 1)
                : _uint(ids[i], AMOUNT + 1);
            bytes memory sig = _sign(a);
            vm.cool(address(vault));
            vm.cool(address(intake));
            assertTrue(intake.completeWithStipend(requestId, a, sig), "ran out of the 200,000 gas stipend");
            // One more than the amount keeps a Pay and breaks the rest; a false Hold is broken.
            assertEq(uint8(_status(ids[i])), uint8(i == 1 ? PinkyVaultV2.Status.Kept : PinkyVaultV2.Status.Broken));
        }
    }

    function test_AFailureReportLandsUnderTheStipendFromCold() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        vm.cool(address(vault));
        vm.cool(address(intake));
        assertTrue(intake.failWithStipend(requestId, 2, bytes32("disagreed")));
        (,,,,,,,,,,,,,,,,,,, bool failed) = vault.promises(id);
        assertTrue(failed);
    }

    function test_ARefusedCallbackUnderTheStipendLeavesTheRequestPending() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        OracleAttestation.Attestation memory a = _uint(id, 0);
        assertFalse(intake.completeWithStipend(requestId, a, _signFor(a, vault, 0xBAD)));
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Asked));
        assertEq(vault.promiseIdFor(address(intake), requestId), id);
        assertFalse(vault.consumed(a.requestId));
        assertTrue(intake.completeWithStipend(requestId, a, _sign(a)));
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Kept));
    }

    // ───────────────────────── asking ─────────────────────────

    /// `settle` closes an active promise and asks for a closed one; every other state is refused,
    /// and `close` closes only once.
    function test_SettleAndCloseRefuseEveryOtherState() public {
        uint256 id = _keep();
        _due();
        vault.close(id);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.close(id);
        // Closed, but the closing block is not yet 32 blocks deep.
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS() - 1);
        vm.expectRevert(PinkyVaultV2.TooEarly.selector);
        vault.settle(id);
        vm.roll(vm.getBlockNumber() + 1);
        bytes32 requestId = vault.settle(id);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.settle(id);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.close(id);
        _answerUint(id, requestId, 0);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.settle(id);
        vault.payout(id);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.settle(id);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.close(id);
    }

    /// Whoever closes, the window ends at the closing block, never before the block of `make`, and
    /// the maker alone may close before the grace.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_CloseIsDueAtTheDeadlineForTheMakerOnly(uint256 at, uint256 blocks, uint8 whoRaw) public {
        uint256 id = _make(PinkyVaultV2.Kind.Keep, address(0), friend);
        (,,,,,,,,,,,, uint64 endTime,,,,,,,) = vault.promises(id);
        at = bound(at, uint256(endTime) - 10, uint256(endTime) + vault.CLOSE_GRACE() + 10);
        blocks = bound(blocks, 0, 1_000);
        address who = [maker, friend, watcher][whoRaw % 3];
        vm.warp(at);
        vm.roll(vm.getBlockNumber() + blocks);
        uint256 due = uint256(endTime) + (who == maker ? 0 : vault.CLOSE_GRACE());
        if (at < due) {
            vm.prank(who);
            vm.expectRevert(PinkyVaultV2.TooEarly.selector);
            vault.close(id);
            assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Active));
            return;
        }
        vm.prank(who);
        vault.close(id);
        (uint64 startBlock, uint64 endBlock) = _window(id);
        assertEq(endBlock, vm.getBlockNumber(), "the window ends at the closing block");
        assertEq(endBlock - startBlock, blocks);
        (,,,,,,,,,,,,, uint64 closedAt,,,,,,) = vault.promises(id);
        assertEq(closedAt, at);
    }

    /// Before the refund is due anyone may ask; from that second on, only the maker or the
    /// beneficiary, and a refusal spends nothing.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_OnlyThePartiesAskOnceTheRefundIsDue(uint256 elapsed, uint8 whoRaw) public {
        uint256 id = _make(PinkyVaultV2.Kind.Keep, address(0), friend);
        _due();
        vault.close(id);
        _confirmed();
        (,,,,,,,,,,,,, uint64 closedAt,,,,,,) = vault.promises(id);
        elapsed = bound(elapsed, 0, 2 * vault.REFUND_GRACE());
        vm.warp(uint256(closedAt) + elapsed);
        address who = [maker, friend, watcher, owner][whoRaw % 4];
        bool party = who == maker || who == friend;
        if (elapsed >= vault.REFUND_GRACE() && !party) {
            vm.prank(who);
            vm.expectRevert(PinkyVaultV2.NotAParty.selector);
            vault.ask(id);
            assertEq(_bond(id), BOND);
            assertEq(_attempts(id), 0);
            // The refund is open to anyone and pays the maker.
            vault.refund(id);
            assertEq(imd.balanceOf(maker), 100 ether);
            return;
        }
        vm.prank(who);
        vault.ask(id);
        assertEq(_bond(id), BOND - PRICE);
        assertEq(_asker(id), who);
    }

    function test_AskRefusesEveryStateButClosedAndAsked() public {
        uint256 id = _keep();
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.ask(id);
        bytes32 requestId = _settle(id);
        _answerUint(id, requestId, 0);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.ask(id);
        vault.payout(id);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.ask(id);
        uint256 later = _keep();
        _due();
        vault.close(later);
        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE());
        vault.refund(later);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.ask(later);
    }

    function test_AskExactlyAtTheTimeout() public {
        uint256 id = _keep();
        _settle(id);
        vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT() - 1);
        vm.expectRevert(PinkyVaultV2.TooEarly.selector);
        vault.ask(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        vault.ask(id);
        assertEq(_attempts(id), 2);
    }

    function test_AWatcherWhoReasksAfterTheMakerTakesTheBounty() public {
        uint256 id = _keep();
        _settleAs(id, maker);
        assertEq(_asker(id), maker);
        vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        vm.prank(watcher);
        bytes32 second = vault.ask(id);
        assertEq(_asker(id), watcher, "the first watcher after a maker takes the seat");
        vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        vm.prank(friend);
        vault.ask(id);
        assertEq(_asker(id), watcher, "and keeps it");
        _answerUint(id, second, AMOUNT + 1);
        vault.payout(id);
        assertEq(imd.balanceOf(watcher), (BOND - 3 * PRICE) / 10);
        assertEq(imd.balanceOf(friend), 0);
    }

    function test_AskLeavesNothingBehindWhenTheIntakeReverts() public {
        uint256 id = _keep();
        RevertingIntakeV2 closed = new RevertingIntakeV2(PRICE);
        vm.prank(owner);
        vault.proposeProtocol(address(closed), ACTION);
        _enact(PinkyVaultV2.Setting.Protocol);
        _due();
        assertEq(vault.settle(id), bytes32(0), "the first settle only closes and calls no Intake");
        _confirmed();
        vm.expectRevert("intake closed");
        vault.settle(id);
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Closed), "a settle that cannot ask stays closed");
        vm.expectRevert("intake closed");
        vault.ask(id);
        assertEq(_bond(id), BOND);
        assertEq(_attempts(id), 0);
        assertEq(imd.allowance(address(vault), address(closed)), 0);
        // The way out does not need the Intake.
        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE());
        vault.refund(id);
        assertEq(imd.balanceOf(maker), 100 ether);
    }

    /// An Intake that only knows version 1 has no `requestWithFailure`: asking reverts, closing and
    /// refunding still work, and the owner can move back.
    function test_AVersionOneIntakeCannotBeAskedButPromisesStillGoHome() public {
        uint256 id = _keep();
        RevertingIntake v1 = new RevertingIntake(PRICE);
        vm.prank(owner);
        vault.proposeProtocol(address(v1), ACTION);
        _enact(PinkyVaultV2.Setting.Protocol);
        _due();
        vault.close(id);
        _confirmed();
        vm.expectRevert();
        vault.settle(id);
        vm.expectRevert();
        vault.ask(id);
        vm.prank(owner);
        vault.proposeProtocol(address(intake), ACTION);
        _enact(PinkyVaultV2.Setting.Protocol);
        vm.roll(vm.getBlockNumber() + 40_000);
        // The move back took a week, so the bond could now be refunded and only a party may ask.
        vm.prank(watcher);
        vm.expectRevert(PinkyVaultV2.NotAParty.selector);
        vault.ask(id);
        vm.prank(maker);
        bytes32 requestId = vault.ask(id);
        _answerUint(id, requestId, 0);
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Kept));
    }

    function test_AskRefusesAnIntakeThatPullsTheWrongAmount() public {
        OddPullIntakeV2 short = new OddPullIntakeV2(PRICE, 1, false);
        OddPullIntakeV2 none = new OddPullIntakeV2(PRICE, PRICE, false);
        uint256 a = _keep();
        uint256 b = _keep();
        vm.prank(owner);
        vault.proposeProtocol(address(short), ACTION);
        _enact(PinkyVaultV2.Setting.Protocol);
        _due();
        vault.settle(a);
        vault.settle(b);
        _confirmed();
        vm.expectRevert(PinkyVaultV2.InvalidPayment.selector);
        vault.settle(a);
        vm.prank(owner);
        vault.proposeProtocol(address(none), ACTION);
        _enact(PinkyVaultV2.Setting.Protocol);
        vm.prank(maker);
        vm.expectRevert(PinkyVaultV2.InvalidPayment.selector);
        vault.settle(b);
        assertEq(imd.balanceOf(address(vault)), 2 * BOND);
        assertEq(imd.allowance(address(vault), address(short)), 0);
        assertEq(imd.allowance(address(vault), address(none)), 0);
    }

    function test_AskRefusesARequestIdTheIntakeAlreadyGaveOut() public {
        OddPullIntakeV2 oneId = new OddPullIntakeV2(PRICE, 0, true);
        PinkyVaultV2 v = _deploy(address(oneId), ACTION, signer, MIN_BOND, PANEL, QUORUM, VALID_FOR);
        vm.startPrank(maker);
        imd.approve(address(v), type(uint256).max);
        uint256 a = v.make(PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 1 hours, BOND);
        uint256 b = v.make(PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 1 hours, BOND);
        vm.stopPrank();
        _due();
        v.settle(a);
        v.settle(b);
        _confirmed();
        v.settle(a);
        vm.expectRevert(PinkyVaultV2.DuplicateRequest.selector);
        v.settle(b);
        assertEq(imd.balanceOf(address(v)), 2 * BOND - PRICE);
    }

    function test_ASwitchAwayAndBackLetsTheHomeIntakeRaiseItsPrice() public {
        uint256 id = _keep();
        MockIntake other = new MockIntake(payee, PRICE);
        vm.prank(owner);
        vault.proposeProtocol(address(other), ACTION);
        _enact(PinkyVaultV2.Setting.Protocol);
        vm.prank(owner);
        vault.proposeProtocol(address(intake), ACTION);
        _enact(PinkyVaultV2.Setting.Protocol);
        intake.setPrice(3 ether);
        _settle(id);
        assertEq(_bond(id), BOND - 3 ether, "the home Intake is paid whatever it asks");
        // A rise above what is left is refused, and the promise can still be refunded.
        intake.setPrice(BOND);
        vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        vm.expectRevert(PinkyVaultV2.InvalidPayment.selector);
        vault.ask(id);
    }

    function test_APriceRiseToTheWholeBondLeavesAKeptMakerNothing() public {
        uint256 id = _keep();
        intake.setPrice(BOND);
        bytes32 requestId = _settle(id);
        assertEq(_bond(id), 0);
        _answerUint(id, requestId, 0);
        uint256 before = imd.balanceOf(maker);
        vault.payout(id);
        assertEq(imd.balanceOf(maker), before);
        assertEq(vault.fees(), 0);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    // ───────────────────────── failures ─────────────────────────

    function test_AFailureAboutASettledPromiseIsRefused() public {
        uint256 id = _keep();
        bytes32 first = _settle(id);
        vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        bytes32 second = vault.ask(id);
        _answerUint(id, second, 0);
        // The first request was never answered; its failure report arrives after the verdict.
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        intake.fail(first, 2, bytes32("disagreed"));
        OracleAttestation.Attestation memory a = _uint(id, AMOUNT + 1);
        bytes memory sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        intake.complete(first, a, sig);
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Kept));
    }

    function test_AFailureEmitsWhatTheIntakeSaid() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        vm.expectEmit(true, true, false, true, address(vault));
        emit PinkyVaultV2.AskFailed(id, requestId, 1, bytes32("body_refused"), 3, 7);
        intake.fail(requestId, 1, bytes32("body_refused"));
    }

    // ───────────────────────── payout ─────────────────────────

    function test_PayoutRefusesTheOtherStates() public {
        uint256 id = _keep();
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.payout(id);
        _due();
        vault.close(id);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.payout(id);
        _confirmed();
        vm.prank(watcher);
        vault.ask(id);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.payout(id);
        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE());
        vault.refund(id);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.payout(id);
    }

    function test_PayoutWhenTheStakerShareIsBelowTheStreamFloorBurnsIt() public {
        PinkyVaultV2 tight = _deploy(address(intake), ACTION, signer, 3 * PRICE, PANEL, QUORUM, VALID_FOR);
        _stake(1 ether);
        vm.startPrank(maker);
        imd.approve(address(tight), type(uint256).max);
        uint256 id = tight.make(
            PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 1 hours, 3 * PRICE + 0.02 ether
        );
        vm.stopPrank();
        _due();
        vm.startPrank(watcher);
        bytes32 requestId = _settleOn(tight, id);
        vm.stopPrank();
        for (uint256 i; i < 2; ++i) {
            vm.warp(vm.getBlockTimestamp() + tight.ANSWER_TIMEOUT());
            vm.prank(watcher);
            requestId = tight.ask(id);
        }
        (,,,,,,,,, uint256 left,,,,,,,,,,) = tight.promises(id);
        assertEq(left, 0.02 ether);
        OracleAttestation.Attestation memory a = _uint(1, 1);
        (,,,,,,,,,, uint64 startBlock, uint64 endBlock,,,,,,,,) = tight.promises(id);
        a.fromBlock = startBlock;
        a.toBlock = endBlock;
        intake.complete(requestId, a, _signFor(a, tight, SIGNER_PK));
        uint256 burnBefore = imd.balanceOf(tight.BURN());
        vm.expectEmit(true, false, false, true, address(tight));
        emit PinkyVaultV2.Paid(id, 0, 0, 0.002 ether, 0, 0.018 ether, 0);
        tight.payout(id);
        assertEq(imd.balanceOf(watcher), 0.002 ether);
        assertEq(imd.balanceOf(address(staking)), 0, "below MIN_REWARD the stakers' share burns");
        assertEq(imd.balanceOf(tight.BURN()) - burnBefore, 0.018 ether);
        assertEq(imd.allowance(address(tight), address(staking)), 0);
    }

    function test_ABrokenPromiseToABeneficiaryPaysNoBountyEvenWithStakers() public {
        _stake(1 ether);
        uint256 id = _make(PinkyVaultV2.Kind.Hold, address(0), friend);
        bytes32 requestId = _settle(id);
        OracleAttestation.Attestation memory a = _attestation(id, OracleAttestation.ANSWER_BOOL, abi.encode(false), 1);
        intake.complete(requestId, a, _sign(a));
        vault.payout(id);
        uint256 left = BOND - PRICE;
        assertEq(imd.balanceOf(friend), left - left / 100);
        assertEq(imd.balanceOf(watcher), 0);
        assertEq(imd.balanceOf(address(staking)), 0);
        assertEq(imd.balanceOf(vault.BURN()), 0);
        assertEq(vault.fees(), left / 100);
    }

    function test_TheFeeRoundsDownOnADustBond() public {
        // A vault with a one-wei minimum against an Intake that charges one wei.
        PinkyVaultV2 tight = _deploy(address(intake), ACTION, signer, 1, PANEL, QUORUM, VALID_FOR);
        intake.setPrice(1);
        vm.startPrank(maker);
        imd.approve(address(tight), type(uint256).max);
        uint256 id = tight.make(PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 1 hours, 99);
        vm.stopPrank();
        _due();
        vm.startPrank(watcher);
        bytes32 requestId = _settleOn(tight, id);
        vm.stopPrank();
        (,,,,,,,,, uint256 left,,,,,,,,,,) = tight.promises(id);
        assertEq(left, 98);
        OracleAttestation.Attestation memory a = _uint(1, 0);
        (,,,,,,,,,, uint64 startBlock, uint64 endBlock,,,,,,,,) = tight.promises(id);
        a.fromBlock = startBlock;
        a.toBlock = endBlock;
        intake.complete(requestId, a, _signFor(a, tight, SIGNER_PK));
        uint256 before = imd.balanceOf(maker);
        tight.payout(id);
        assertEq(imd.balanceOf(maker) - before, 98, "98 wei carries no fee");
        assertEq(tight.fees(), 0);
        assertEq(imd.balanceOf(address(tight)), 0);
    }

    function test_PaidEmitsEveryShare() public {
        _stake(1 ether);
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        _answerUint(id, requestId, AMOUNT + 1);
        uint256 left = BOND - PRICE;
        uint256 bounty = left / 10;
        uint256 toStakers = (left - bounty) / 2;
        vm.expectEmit(true, false, false, true, address(vault));
        emit PinkyVaultV2.Paid(id, 0, 0, bounty, toStakers, left - bounty - toStakers, 0);
        vault.payout(id);
    }

    // ───────────────────────── refund ─────────────────────────

    function test_RefundOfAClosedPromiseWaitsSevenDaysFromClosing() public {
        uint256 id = _keep();
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.refund(id);
        _due();
        vault.close(id);
        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE() - 1);
        vm.expectRevert(PinkyVaultV2.TooEarly.selector);
        vault.refund(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PinkyVaultV2.Refunded(id, BOND);
        vm.prank(watcher);
        vault.refund(id);
        assertEq(imd.balanceOf(maker), 100 ether, "the whole bond, to the maker, whoever calls");
        assertEq(imd.balanceOf(watcher), 0);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.refund(id);
    }

    function test_RefundAfterOneUnansweredAskWaitsForTheGrace() public {
        uint256 id = _keep();
        _settle(id);
        vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        vm.expectRevert(PinkyVaultV2.TooEarly.selector);
        vault.refund(id);
        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE() - vault.ANSWER_TIMEOUT() - 1);
        vm.expectRevert(PinkyVaultV2.TooEarly.selector);
        vault.refund(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        vault.refund(id);
        assertEq(imd.balanceOf(maker), 100 ether - PRICE);
    }

    function test_AnAnswerToARefundedRequestIsRefused() public {
        uint256 id = _keep();
        bytes32 first = _settle(id);
        vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        bytes32 second = vault.ask(id);
        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE());
        vault.refund(id);
        assertEq(vault.promiseIdFor(address(intake), second), 0, "the latest request is forgotten");
        OracleAttestation.Attestation memory a = _uint(id, AMOUNT + 1);
        bytes memory sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.UnknownRequest.selector);
        intake.complete(second, a, sig);
        // The earlier request is still remembered, and still cannot move anything.
        assertEq(vault.promiseIdFor(address(intake), first), id);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        intake.complete(first, a, sig);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        intake.fail(first, 2, bytes32("disagreed"));
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_RefundRefusesSettledPromises() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        _answerUint(id, requestId, 0);
        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE());
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.refund(id);
        vault.payout(id);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.refund(id);
    }

    // ───────────────────────── fees and sinks ─────────────────────────

    function _earnFee() internal returns (uint256 fee) {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        _answerUint(id, requestId, 0);
        vault.payout(id);
        fee = vault.fees();
    }

    function _setSink(address sink) internal {
        vm.prank(owner);
        vault.proposeFeeSink(sink);
        _enact(PinkyVaultV2.Setting.FeeSink);
    }

    function test_SendFeesWithNothingToSendIsANoOp() public {
        _stake(1 ether);
        vault.sendFees();
        assertEq(imd.balanceOf(address(staking)), 0);
    }

    function test_ASinkThatTakesLessThanTheFeesIsRefused() public {
        uint256 fee = _earnFee();
        ShortSink less = new ShortSink(address(imd), 1);
        _setSink(address(less));
        vm.expectRevert(PinkyVaultV2.InvalidPayment.selector);
        vault.sendFees();
        ShortSink nothing = new ShortSink(address(imd), fee);
        _setSink(address(nothing));
        vm.expectRevert(PinkyVaultV2.InvalidPayment.selector);
        vault.sendFees();
        assertEq(vault.fees(), fee, "the fees are still owed");
        assertEq(imd.balanceOf(address(vault)), fee);
        assertEq(imd.allowance(address(vault), address(less)), 0);
    }

    function test_ASinkWithoutNotifyOrOneThatRefusesKeepsTheFeesHere() public {
        uint256 fee = _earnFee();
        DeafSink deaf = new DeafSink();
        _setSink(address(deaf));
        vault.sendFees();
        assertEq(vault.fees(), fee);
        RefusingSink no = new RefusingSink();
        _setSink(address(no));
        vault.sendFees();
        assertEq(vault.fees(), fee);
        assertEq(imd.balanceOf(address(vault)), fee);
        assertEq(imd.allowance(address(vault), address(deaf)), 0);
        assertEq(imd.allowance(address(vault), address(no)), 0);
        // Back to a pool with stakers: everything owed goes at once.
        _setSink(address(staking));
        _stake(1 ether);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PinkyVaultV2.FeesSent(address(staking), fee);
        vault.sendFees();
        assertEq(vault.fees(), 0);
        assertEq(imd.balanceOf(address(staking)), fee);
    }

    /// A fee under PinkyStaking's 0.01 IMD floor is refused by the pool and waits here until more
    /// accrues; then everything owed goes in one call.
    function test_FeesBelowTheStreamFloorWaitAndAccrue() public {
        PinkyVaultV2 tight = _deploy(address(intake), ACTION, signer, 3 * PRICE, PANEL, QUORUM, VALID_FOR);
        _stake(1 ether);
        vm.startPrank(maker);
        imd.approve(address(tight), type(uint256).max);
        uint256 first = tight.make(
            PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 1 hours, 3 * PRICE + 0.2 ether
        );
        uint256 second = tight.make(
            PinkyVaultV2.Kind.Keep, address(token), 0, address(0), address(0), 1 hours, 3 * PRICE + 0.2 ether
        );
        vm.stopPrank();
        _due();
        uint256[2] memory ids = [first, second];
        for (uint256 i; i < 2; ++i) {
            _settleOn(tight, ids[i]);
            vm.warp(vm.getBlockTimestamp() + tight.ANSWER_TIMEOUT());
            bytes32 requestId = tight.ask(ids[i]);
            OracleAttestation.Attestation memory a = _uint(1, 0);
            (,,,,,,,,,, uint64 startBlock, uint64 endBlock,,,,,,,,) = tight.promises(ids[i]);
            a.fromBlock = startBlock;
            a.toBlock = endBlock;
            a.requestId = bytes32(bytes16(keccak256(abi.encode("tight", i))));
            intake.complete(requestId, a, _signFor(a, tight, SIGNER_PK));
        }
        tight.payout(first);
        uint256 fee = tight.fees();
        assertEq(fee, 0.007 ether, "one percent of the 0.7 IMD left");
        assertLt(fee, staking.MIN_REWARD());
        tight.sendFees();
        assertEq(tight.fees(), fee, "below the floor the pool refuses and the fee waits");
        assertEq(imd.balanceOf(address(staking)), 0);
        tight.payout(second);
        assertEq(tight.fees(), 2 * fee);
        tight.sendFees();
        assertEq(tight.fees(), 0);
        assertEq(imd.balanceOf(address(staking)), 2 * fee);
        assertEq(imd.balanceOf(address(tight)), 0);
    }

    function test_TheBrokenSplitAlwaysGoesToTheLaunchStakingNotTheSink() public {
        _stake(1 ether);
        PinkyStaking otherPool = new PinkyStaking(address(pinky), address(imd));
        _setSink(address(otherPool));
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        _answerUint(id, requestId, AMOUNT + 1);
        vault.payout(id);
        uint256 left = BOND - PRICE;
        assertEq(imd.balanceOf(address(staking)), (left - left / 10) / 2, "the split is the immutable pool's");
        assertEq(imd.balanceOf(address(otherPool)), 0);
    }

    // ───────────────────────── settings ─────────────────────────

    function test_NobodyButTheOwnerProposesAndAnyoneEnacts() public {
        vm.startPrank(watcher);
        vm.expectRevert(PinkyVaultV2.OnlyOwner.selector);
        vault.proposeProtocol(address(intake), ACTION);
        vm.expectRevert(PinkyVaultV2.OnlyOwner.selector);
        vault.proposePanel(9, 7, 3_600);
        vm.expectRevert(PinkyVaultV2.OnlyOwner.selector);
        vault.proposeFeeSink(address(staking));
        vm.expectRevert(PinkyVaultV2.OnlyOwner.selector);
        vault.proposeSigner(watcher);
        vm.stopPrank();
        vm.prank(owner);
        vault.proposeSigner(watcher);
        vm.warp(vm.getBlockTimestamp() + vault.SETTINGS_DELAY());
        vm.prank(watcher);
        vault.enact(PinkyVaultV2.Setting.Signer);
        assertEq(vault.oracleSigner(), watcher);
    }

    function test_ProposalsAreOnePerSettingAndTheLatestWins() public {
        vm.startPrank(owner);
        vault.proposePanel(9, 7, 3_600);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vault.proposePanel(11, 8, 7_200);
        vm.stopPrank();
        (bytes32 data,, uint64 eta) = vault.pending(PinkyVaultV2.Setting.Panel);
        assertEq(eta, vm.getBlockTimestamp() + 7 days, "the clock restarts");
        assertEq(uint256(data), uint256(11) << 48 | uint256(8) << 32 | 7_200);
        vm.warp(vm.getBlockTimestamp() + 4 days);
        vm.expectRevert(PinkyVaultV2.TooEarly.selector);
        vault.enact(PinkyVaultV2.Setting.Panel);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vault.enact(PinkyVaultV2.Setting.Panel);
        assertEq(vault.panelSize(), 11);
        assertEq(vault.quorum(), 8);
        assertEq(vault.validForSeconds(), 7_200);
    }

    function test_CancelAndEnactRefuseAnEmptySlot() public {
        vm.prank(owner);
        vm.expectRevert(PinkyVaultV2.NothingPending.selector);
        vault.cancel(PinkyVaultV2.Setting.FeeSink);
        vm.expectRevert(PinkyVaultV2.NothingPending.selector);
        vault.enact(PinkyVaultV2.Setting.FeeSink);
        // Each setting has its own slot.
        vm.prank(owner);
        vault.proposeSigner(watcher);
        vm.expectRevert(PinkyVaultV2.NothingPending.selector);
        vault.enact(PinkyVaultV2.Setting.Protocol);
    }

    function test_PanelProposalBoundaries() public {
        vm.startPrank(owner);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        vault.proposePanel(1, 1, 3_600);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        vault.proposePanel(101, 5, 3_600);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        vault.proposePanel(7, 1, 3_600);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        vault.proposePanel(7, 5, 59);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        vault.proposePanel(7, 5, 30 days + 1);
        vault.proposePanel(100, 100, 30 days);
        vault.proposePanel(2, 2, 60);
        vm.stopPrank();
    }

    /// A promise is held to the smallest panel any of its requests paid for, never a smaller one.
    function test_ALoweredPanelAppliesOnlyToRequestsPaidUnderIt() public {
        uint256 id = _keep();
        bytes32 first = _settle(id);
        vm.prank(owner);
        vault.proposePanel(3, 2, 3_600);
        _enact(PinkyVaultV2.Setting.Panel);
        // The first request still wants the panel it paid for.
        OracleAttestation.Attestation memory a = _uint(id, 0);
        a.panelSize = 3;
        a.quorum = 2;
        a.agreed = 2;
        bytes memory sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.InvalidAttestation.selector);
        intake.complete(first, a, sig);
        // After a re-ask under the smaller panel, the smaller panel is enough for any request. A
        // week has passed since closing, so only a party may ask again.
        vm.prank(watcher);
        vm.expectRevert(PinkyVaultV2.NotAParty.selector);
        vault.ask(id);
        vm.prank(maker);
        bytes32 second = vault.ask(id);
        (, uint16 panel, uint16 quorum,,,) = vault.terms(id);
        assertEq(panel, 3);
        assertEq(quorum, 2);
        a = _uint(id, 0);
        a.panelSize = 3;
        a.quorum = 2;
        a.agreed = 2;
        intake.complete(first, a, _sign(a));
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Kept));
        second;
    }

    /// A rotation applies to requests bought after it. A request already in flight takes an answer
    /// from the key it was bought under or the new one, and from no third key.
    function test_ARotatedSignerStillAnswersTheRequestsBoughtUnderIt() public {
        uint256 id = _keep();
        uint256 later = _keep();
        bytes32 requestId = _settle(id);
        uint256 nextPk = 0xB0B;
        vm.prank(owner);
        vault.proposeSigner(vm.addr(nextPk));
        OracleAttestation.Attestation memory a = _uint(id, 0);
        bytes memory byNext = _signFor(a, vault, nextPk);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, byNext);
        _enact(PinkyVaultV2.Setting.Signer);
        assertEq(vault.oracleSigner(), vm.addr(nextPk));
        (,,,,, address boughtUnder) = vault.terms(id);
        assertEq(boughtUnder, signer, "the request was bought under the old key");
        // A week later: a fresh attestation. A third key is refused; the old key is still taken.
        a = _uint(id, 0);
        bytes memory byThird = _signFor(a, vault, 0xBAD);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, byThird);
        intake.complete(requestId, a, _sign(a));
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Kept));
        // A promise asked after the rotation takes only the new key.
        vm.prank(maker);
        vault.close(later);
        _confirmed();
        vm.prank(maker);
        bytes32 laterRequest = vault.ask(later);
        (,,,,, boughtUnder) = vault.terms(later);
        assertEq(boughtUnder, vm.addr(nextPk));
        OracleAttestation.Attestation memory b = _uint(later, 0);
        bytes memory byOld = _sign(b);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(laterRequest, b, byOld);
        intake.complete(laterRequest, b, _signFor(b, vault, nextPk));
        assertEq(uint8(_status(later)), uint8(PinkyVaultV2.Status.Kept));
    }

    /// The key is the promise's, not each request's: a re-ask after a rotation moves every request
    /// the promise still has in flight to the key current at that ask.
    function test_AReaskAfterARotationMovesThePromiseToTheNewKey() public {
        uint256 id = _keep();
        bytes32 first = _settle(id);
        uint256 nextPk = 0xB0B;
        vm.prank(owner);
        vault.proposeSigner(vm.addr(nextPk));
        _enact(PinkyVaultV2.Setting.Signer);
        vm.prank(maker);
        bytes32 second = vault.ask(id);
        (,,,,, address boughtUnder) = vault.terms(id);
        assertEq(boughtUnder, vm.addr(nextPk), "the latest ask decides the key");
        // The first request, answered by the key it was bought under, is now refused.
        OracleAttestation.Attestation memory a = _uint(id, 0);
        bytes memory byOld = _sign(a);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(first, a, byOld);
        intake.complete(first, a, _signFor(a, vault, nextPk));
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Kept));
        assertEq(vault.promiseIdFor(address(intake), second), id, "the other request is left to time out");
    }

    function test_TheOwnerCannotMoveABond() public {
        uint256 id = _keep();
        vm.startPrank(owner);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.payout(id);
        vm.expectRevert(PinkyVaultV2.WrongStatus.selector);
        vault.refund(id);
        vm.expectRevert(PinkyVaultV2.TooEarly.selector);
        vault.settle(id);
        vm.stopPrank();
        // No setting reaches the bonds: a new sink only ever sees the fees.
        ShortSink greedy = new ShortSink(address(imd), 0);
        _setSink(address(greedy));
        vault.sendFees();
        assertEq(imd.balanceOf(address(vault)), BOND);
        assertEq(imd.balanceOf(address(greedy)), 0);
    }

    function test_SettingsEmitTheirEvents() public {
        uint64 eta = uint64(vm.getBlockTimestamp() + 7 days);
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PinkyVaultV2.Proposed(
            PinkyVaultV2.Setting.Protocol, bytes32(uint256(uint160(address(intake)))), ACTION, eta
        );
        vault.proposeProtocol(address(intake), ACTION);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PinkyVaultV2.Cancelled(PinkyVaultV2.Setting.Protocol);
        vault.cancel(PinkyVaultV2.Setting.Protocol);
        vault.proposeProtocol(address(intake), bytes32("oracle.request@oracle-2"));
        vm.stopPrank();
        vm.warp(eta);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PinkyVaultV2.ProtocolSet(address(intake), bytes32("oracle.request@oracle-2"));
        vault.enact(PinkyVaultV2.Setting.Protocol);
    }

    // ───────────────────────── fuzz ─────────────────────────

    /// forge-config: default.fuzz.runs = 512
    /// Every verdict for every kind is exactly the comparison the promise states, at any amount.
    function testFuzz_VerdictIsTheStatedComparison(uint8 kindRaw, uint256 amount, uint256 out) public {
        PinkyVaultV2.Kind kind = PinkyVaultV2.Kind(bound(kindRaw, 0, 3));
        amount =
            bound(amount, kind == PinkyVaultV2.Kind.Keep || kind == PinkyVaultV2.Kind.Moves ? 0 : 1, type(uint128).max);
        vm.prank(maker);
        uint256 id = vault.make(
            kind, address(token), amount, kind == PinkyVaultV2.Kind.Pay ? friend : address(0), address(0), 1 hours, BOND
        );
        bytes32 requestId = _settle(id);
        bool kept;
        OracleAttestation.Attestation memory a;
        if (kind == PinkyVaultV2.Kind.Hold) {
            kept = out >= amount;
            a = _attestation(id, OracleAttestation.ANSWER_BOOL, abi.encode(kept), out);
        } else {
            kept = kind == PinkyVaultV2.Kind.Pay ? out >= amount : out <= amount;
            a = _uint(id, out);
        }
        intake.complete(requestId, a, _sign(a));
        assertEq(uint8(_status(id)), uint8(kept ? PinkyVaultV2.Status.Kept : PinkyVaultV2.Status.Broken));
        (,,,,,,,,,,,,,,,,,, uint256 observed,) = vault.promises(id);
        assertEq(observed, out);
    }

    /// forge-config: default.fuzz.runs = 512
    /// The fee is exactly one percent, rounded down, of what is left after the oracle was paid,
    /// and the rest reaches the maker or the beneficiary to the wei.
    function testFuzz_OnePercentOfWhatIsLeft(uint256 bond, uint256 price, bool toFriend, bool broken) public {
        price = bound(price, 0.05 ether, 3 ether);
        bond = bound(bond, 3 * price > MIN_BOND ? 3 * price : MIN_BOND, 100 ether);
        intake.setPrice(price);
        vm.prank(maker);
        uint256 id = vault.make(
            PinkyVaultV2.Kind.Keep, address(token), 0, address(0), toFriend ? friend : address(0), 1 hours, bond
        );
        bytes32 requestId = _settle(id);
        _answerUint(id, requestId, broken ? 1 : 0);
        uint256 makerBefore = imd.balanceOf(maker);
        vault.payout(id);
        uint256 left = bond - price;
        uint256 fee = left / 100;
        if (!broken) {
            assertEq(imd.balanceOf(maker) - makerBefore, left - fee);
            assertEq(vault.fees(), fee);
        } else if (toFriend) {
            assertEq(imd.balanceOf(friend), left - fee);
            assertEq(vault.fees(), fee);
        } else {
            assertEq(vault.fees(), 0);
            assertEq(imd.balanceOf(watcher), left / 10);
            assertEq(imd.balanceOf(vault.BURN()), left - left / 10);
        }
        assertEq(imd.balanceOf(address(vault)), vault.fees());
    }
}
