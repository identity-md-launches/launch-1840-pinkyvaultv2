// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {PinkyVault} from "../src/PinkyVault.sol";
import {PinkyStaking} from "../src/PinkyStaking.sol";
import {MockERC20, MockIntake} from "./mocks/Mocks.sol";

contract PinkyVaultTest is Test {
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");
    uint256 constant PRICE = 0.5 ether;
    uint256 constant MIN_BOND = 5 ether;
    uint256 constant BOND = 10 ether;
    uint256 constant MAX_OUT = 1_000 ether;
    uint256 constant SIGNER_PK = 0xA11CE;

    MockERC20 imd;
    MockERC20 pinky;
    MockERC20 token;
    MockIntake intake;
    PinkyStaking staking;
    PinkyVault vault;

    address owner = makeAddr("owner");
    address payee = makeAddr("payee");
    address maker = makeAddr("maker");
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
        intake = new MockIntake(payee, PRICE);
        staking = new PinkyStaking(address(pinky), address(imd));
        vault = new PinkyVault(
            owner, address(imd), address(staking), address(intake), ACTION, signer, MIN_BOND, 5, 4, 86_400
        );
        imd.mint(maker, 100 ether);
        vm.prank(maker);
        imd.approve(address(vault), type(uint256).max);
    }

    // ───────────────────────── helpers ─────────────────────────

    function _make() internal returns (uint256 id) {
        vm.prank(maker);
        id = vault.make(address(token), MAX_OUT, 1 hours, BOND);
    }

    function _close(uint256 id) internal {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 36_000);
        vault.close(id);
    }

    function _ask(uint256 id) internal returns (bytes32 requestId) {
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());
        vm.prank(watcher);
        requestId = vault.ask(id);
    }

    function _attestation(uint256 id, uint256 out, bytes16 oracleId)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        (,,,, uint64 startBlock, uint64 endBlock,,,,,,,,,,) = vault.promises(id);
        a.requestId = bytes32(oracleId);
        a.chainId = block.chainid;
        a.questionHash = keccak256("q");
        a.answerType = 3;
        a.answer = abi.encode(out);
        a.figure = out;
        a.fromBlock = startBlock;
        a.toBlock = endBlock;
        a.blockHash = keccak256("b");
        a.panelJobId = keccak256("p");
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 86_400);
    }

    function _sign(OracleAttestation.Attestation memory a, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, vault.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _answer(uint256 id, bytes32 requestId, uint256 out) internal returns (uint256 gasUsed) {
        OracleAttestation.Attestation memory a = _attestation(id, out, bytes16(keccak256(abi.encode(requestId))));
        gasUsed = intake.complete(requestId, a, _sign(a, SIGNER_PK));
    }

    function _status(uint256 id) internal view returns (PinkyVault.Status status) {
        (,,,,,,,,,, status,,,,,) = vault.promises(id);
    }

    function _bond(uint256 id) internal view returns (uint256 bond) {
        (,,, bond,,,,,,,,,,,,) = vault.promises(id);
    }

    // ───────────────────────── make ─────────────────────────

    function test_MakePullsTheBondAndRecordsTheBlock() public {
        uint256 id = _make();
        assertEq(id, 1);
        assertEq(imd.balanceOf(address(vault)), BOND);
        (address m, address t, uint256 maxOut, uint256 bond, uint64 startBlock,, uint64 endTime,,,,,,,,,) =
            vault.promises(id);
        assertEq(m, maker);
        assertEq(t, address(token));
        assertEq(maxOut, MAX_OUT);
        assertEq(bond, BOND);
        assertEq(startBlock, 1_000);
        assertEq(endTime, vm.getBlockTimestamp() + 1 hours);
    }

    function test_MakeUsesTheArbitrumBlockNumberWhereThereIsOne() public {
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(uint256(84_000_000)));
        uint256 id = _make();
        (,,,, uint64 startBlock,,,,,,,,,,,) = vault.promises(id);
        assertEq(startBlock, 84_000_000);
    }

    function test_MakeRefusesBadInput() public {
        vm.startPrank(maker);
        vm.expectRevert(PinkyVault.InvalidPromise.selector);
        vault.make(makeAddr("not a contract"), MAX_OUT, 1 hours, BOND);
        vm.expectRevert(PinkyVault.InvalidPromise.selector);
        vault.make(address(imd), MAX_OUT, 1 hours, BOND);
        vm.expectRevert(PinkyVault.InvalidPromise.selector);
        vault.make(address(token), MAX_OUT, 9 minutes, BOND);
        vm.expectRevert(PinkyVault.InvalidPromise.selector);
        vault.make(address(token), MAX_OUT, 31 days, BOND);
        vm.expectRevert(PinkyVault.BondTooSmall.selector);
        vault.make(address(token), MAX_OUT, 1 hours, MIN_BOND - 1);
        vm.stopPrank();

        intake.setPrice(4 ether);
        vm.prank(maker);
        vm.expectRevert(PinkyVault.BondTooSmall.selector);
        vault.make(address(token), MAX_OUT, 1 hours, BOND);
    }

    // ───────────────────────── close and ask ─────────────────────────

    function test_CloseOnlyAfterTheDeadlineAndOnlyOnce() public {
        uint256 id = _make();
        vm.expectRevert(PinkyVault.TooEarly.selector);
        vault.close(id);
        _close(id);
        (,,,,, uint64 endBlock,,,,,,,,,,) = vault.promises(id);
        assertEq(endBlock, 37_000);
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.close(id);
    }

    function test_AskWaitsForTheSettleDelay() public {
        uint256 id = _make();
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.ask(id);
        _close(id);
        vm.expectRevert(PinkyVault.TooEarly.selector);
        vault.ask(id);
    }

    function test_AskPaysTheIntakeFromTheBond() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        assertEq(imd.balanceOf(payee), PRICE);
        assertEq(imd.balanceOf(address(vault)), BOND - PRICE);
        assertEq(_bond(id), BOND - PRICE);
        assertEq(imd.allowance(address(vault), address(intake)), 0);
        assertEq(vault.promiseIdFor(address(intake), requestId), id);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Asked));
    }

    function test_BodyIsTheJsonTheOracleExpects() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        string memory body = string(intake.bodyOf(requestId));
        assertEq(body, vault.bodyOf(id));

        assertEq(vm.parseJsonUint(body, ".v"), 1);
        assertEq(vm.parseJsonUint(body, ".chainId"), block.chainid);
        assertEq(vm.parseJsonUint(body, ".window.fromBlock"), 1_000);
        assertEq(vm.parseJsonUint(body, ".window.toBlock"), 37_000);
        assertEq(vm.parseJsonString(body, ".answerType"), "uint256");
        assertEq(vm.parseJsonString(body, ".evidence"), "chain");
        assertEq(vm.parseJsonUint(body, ".panelSize"), 5);
        assertEq(vm.parseJsonUint(body, ".quorum"), 4);
        assertEq(vm.parseJsonUint(body, ".toleranceBps"), 0);
        assertEq(vm.parseJsonUint(body, ".validForSeconds"), 86_400);
        assertLe(bytes(vm.parseJsonString(body, ".question")).length, 2_000);

        string memory definition = vm.parseJsonString(body, ".definitions.recipe");
        assertLe(bytes(definition).length, 512);
        string memory recipe = vm.replace(definition, " - write recipe exactly this, event text included.", "");
        assertEq(vm.parseJsonString(recipe, ".kind"), "log-sum");
        assertEq(vm.parseJsonAddress(recipe, ".address"), address(token));
        assertEq(
            vm.parseJsonString(recipe, ".event"),
            "event Transfer(address indexed from, address indexed to, uint256 value)"
        );
        assertEq(vm.parseJsonString(recipe, ".sumArg"), "value");
        assertEq(vm.parseJsonBool(recipe, ".abs"), false);
        assertEq(vm.parseJsonAddress(recipe, ".filter.from"), maker);
    }

    // ───────────────────────── verdict and payout ─────────────────────────

    function test_KeptPromiseReturnsTheBond() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        uint256 gasUsed = _answer(id, requestId, MAX_OUT);
        assertLt(gasUsed, 200_000, "the Intake gives the callback 200,000 gas");
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Kept));

        vault.payout(id);
        assertEq(imd.balanceOf(maker), 100 ether - PRICE);
        assertEq(imd.balanceOf(address(vault)), 0);
        vm.expectRevert(PinkyVault.AlreadyPaid.selector);
        vault.payout(id);
    }

    function test_BrokenPromiseWithNoStakersPaysTheAskerAndBurnsTheRest() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        _answer(id, requestId, MAX_OUT + 1);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Broken));

        vault.payout(id);
        uint256 left = BOND - PRICE;
        assertEq(imd.balanceOf(watcher), left / 10);
        assertEq(imd.balanceOf(vault.BURN()), left - left / 10);
        assertEq(imd.balanceOf(maker), 100 ether - BOND);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_BrokenPromiseSharesWithStakers() public {
        pinky.mint(staker, 1_000 ether);
        vm.startPrank(staker);
        pinky.approve(address(staking), type(uint256).max);
        staking.stake(1_000 ether);
        vm.stopPrank();

        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        _answer(id, requestId, MAX_OUT + 1);
        vault.payout(id);

        uint256 left = BOND - PRICE;
        uint256 bounty = left / 10;
        uint256 toStakers = (left - bounty) / 2;
        assertEq(imd.balanceOf(watcher), bounty);
        assertEq(imd.balanceOf(address(staking)), toStakers);
        assertEq(imd.balanceOf(vault.BURN()), left - bounty - toStakers);
        assertEq(imd.allowance(address(vault), address(staking)), 0);

        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertApproxEqAbs(staking.earned(staker), toStakers, 1e6);
        vm.prank(staker);
        staking.claim();
        assertApproxEqAbs(imd.balanceOf(staker), toStakers, 1e6);
    }

    function test_PayoutNeedsAVerdict() public {
        uint256 id = _make();
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.payout(id);
        vm.expectRevert(PinkyVault.UnknownPromise.selector);
        vault.payout(2);
    }

    // ───────────────────────── attestation checks ─────────────────────────

    function test_RefusesAnAnswerFromAnotherSigner() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        bytes memory sig = _sign(a, 0xBAD);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, sig);
    }

    function test_RefusesAnAnswerForAnotherBlockRange() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);

        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        a.fromBlock += 1;
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(PinkyVault.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);

        a = _attestation(id, 0, bytes16("x"));
        a.toBlock -= 1;
        sig = _sign(a, SIGNER_PK);
        vm.expectRevert(PinkyVault.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);

        a = _attestation(id, 0, bytes16("x"));
        a.chainId = 1;
        sig = _sign(a, SIGNER_PK);
        vm.expectRevert(PinkyVault.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);

        a = _attestation(id, 0, bytes16("x"));
        a.panelSize = 4;
        sig = _sign(a, SIGNER_PK);
        vm.expectRevert(PinkyVault.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);
    }

    function test_RefusesAnAnswerThePanelDidNotAgreeOn() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        a.agreed = 3;
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(PinkyVault.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);

        a = _attestation(id, 0, bytes16("x"));
        a.agreed = 4;
        sig = _sign(a, SIGNER_PK);
        intake.complete(requestId, a, sig);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Kept));
    }

    function test_ChangingThePanelDuringARequestDoesNotRefuseItsAnswer() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        (, uint16 askedPanel, uint16 askedQuorum,,) = vault.terms(id);
        assertEq(askedPanel, 5);
        assertEq(askedQuorum, 4);
        assertEq(vm.parseJsonUint(string(intake.bodyOf(requestId)), ".panelSize"), 5);

        vm.prank(owner);
        vault.setPanel(9, 6, 86_400);
        _answer(id, requestId, MAX_OUT + 1);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Broken));
    }

    function test_ARequestBoughtWithASmallerPanelIsStillAnswerable() public {
        uint256 id = _make();
        _close(id);
        bytes32 first = _ask(id);
        vm.prank(owner);
        vault.setPanel(9, 6, 86_400);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        bytes32 second = _ask(id);
        assertEq(vm.parseJsonUint(string(intake.bodyOf(second)), ".panelSize"), 9);
        (, uint16 askedPanel, uint16 askedQuorum,,) = vault.terms(id);
        assertEq(askedPanel, 5);
        assertEq(askedQuorum, 4);
        _answer(id, first, 0);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Kept));
    }

    function test_CallbackFitsTheIntakeStipendFromColdStorage() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        OracleAttestation.Attestation memory a = _attestation(id, MAX_OUT + 1, bytes16("cold"));
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.cool(address(vault));
        vm.cool(address(intake));
        uint256 gasUsed = intake.complete(requestId, a, sig);
        assertLt(gasUsed, 200_000, "the Intake gives the callback 200,000 gas");
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Broken));
    }

    function test_RefusesAnAnswerOfAnotherType() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        a.answerType = 0;
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, 3, 0));
        intake.complete(requestId, a, sig);
    }

    function test_OnlyTheIntakeThatWasAskedCanAnswer() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(PinkyVault.UnknownRequest.selector);
        vault.onOracleResult(requestId, a, sig);
    }

    function test_AnAnswerCannotBeDeliveredTwice() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        _answer(id, requestId, 0);
        OracleAttestation.Attestation memory a = _attestation(id, MAX_OUT + 1, bytes16("y"));
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(PinkyVault.UnknownRequest.selector);
        intake.complete(requestId, a, sig);
    }

    // ───────────────────────── no answer ─────────────────────────

    /// @dev Changed with the audit fix for third-party re-asks: a request the bond paid for stays
    /// answerable until a verdict lands, so a late answer to the first request still counts.
    function test_AskAgainAfterATimeoutAndEitherAnswerCounts() public {
        uint256 id = _make();
        _close(id);
        bytes32 first = _ask(id);
        vm.expectRevert(PinkyVault.TooEarly.selector);
        vault.ask(id);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        bytes32 second = _ask(id);
        assertTrue(first != second);
        assertEq(_bond(id), BOND - 2 * PRICE);
        assertEq(vault.promiseIdFor(address(intake), first), id);
        assertEq(vault.promiseIdFor(address(intake), second), id);

        _answer(id, first, 0);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Kept));

        OracleAttestation.Attestation memory a = _attestation(id, MAX_OUT + 1, bytes16("y"));
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        intake.complete(second, a, sig);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Kept));
    }

    function test_AThirdPartyReaskDoesNotTakeTheWatchersBounty() public {
        uint256 id = _make();
        _close(id);
        _ask(id);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.roll(vm.getBlockNumber() + 1);
        address griefer = makeAddr("griefer");
        vm.prank(griefer);
        bytes32 second = vault.ask(id);
        (,,,,,,,,,,,, address asker,,,) = vault.promises(id);
        assertEq(asker, watcher);

        _answer(id, second, MAX_OUT + 1);
        vault.payout(id);
        uint256 left = BOND - 2 * PRICE;
        assertEq(imd.balanceOf(watcher), left / 10);
        assertEq(imd.balanceOf(griefer), 0);
    }

    function test_AMakerWhoAsksFirstYieldsTheBountyToTheWatcherWhoReasks() public {
        uint256 id = _make();
        _close(id);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());
        vm.prank(maker);
        vault.ask(id);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        bytes32 second = _ask(id);
        (,,,,,,,,,,,, address asker,,,) = vault.promises(id);
        assertEq(asker, watcher);
        _answer(id, second, MAX_OUT + 1);
        vault.payout(id);
        assertEq(imd.balanceOf(watcher), (BOND - 2 * PRICE) / 10);
    }

    function test_AMakerWhoAsksAboutTheirOwnBrokenPromiseGetsNoBounty() public {
        uint256 id = _make();
        _close(id);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());
        vm.prank(maker);
        bytes32 requestId = vault.ask(id);
        _answer(id, requestId, MAX_OUT + 1);
        vault.payout(id);
        uint256 left = BOND - PRICE;
        assertEq(imd.balanceOf(maker), 100 ether - BOND, "a broken maker gets nothing back");
        assertEq(imd.balanceOf(vault.BURN()), left, "with no stakers the whole remainder burns");
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_AMakerWhoAsksAboutTheirOwnKeptPromiseStillGetsTheBond() public {
        uint256 id = _make();
        _close(id);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());
        vm.prank(maker);
        bytes32 requestId = vault.ask(id);
        _answer(id, requestId, 0);
        vault.payout(id);
        assertEq(imd.balanceOf(maker), 100 ether - PRICE);
    }

    /// @dev Audit finding: the owner could point `ask` at an Intake whose price equals a bond.
    /// Another Intake, or another action, is held to the price the promise was made under.
    function test_AskRefusesAPriceAboveTheOneTheBondWasMadeUnderAtAnotherProtocol() public {
        uint256 id = _make();
        (uint256 maxPrice,,, address madeUnder, bytes32 madeFor) = vault.terms(id);
        assertEq(maxPrice, PRICE);
        assertEq(madeUnder, address(intake));
        assertEq(madeFor, ACTION);
        _close(id);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());

        MockIntake greedy = new MockIntake(payee, BOND);
        vm.prank(owner);
        vault.setProtocol(address(greedy), ACTION);
        vm.expectRevert(PinkyVault.InvalidPayment.selector);
        vault.ask(id);
        assertEq(imd.balanceOf(address(vault)), BOND);

        // The same Intake selling another action is another protocol too.
        intake.setPrice(PRICE + 1);
        vm.prank(owner);
        vault.setProtocol(address(intake), bytes32("oracle.request@oracle-2"));
        vm.expectRevert(PinkyVault.InvalidPayment.selector);
        vault.ask(id);

        // At or under the price the promise was made under, another protocol is fine.
        intake.setPrice(PRICE - 1);
        vault.ask(id);
        assertEq(_bond(id), BOND - (PRICE - 1));
    }

    /// @dev Review finding: a price rise at the Intake the promise was made under used to leave
    /// every open promise with no exit but a full refund. Now the bond pays the new price.
    function test_APriceRiseAtTheProtocolThePromiseWasMadeUnderIsPaidFromTheBond() public {
        uint256 id = _make();
        _close(id);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());

        intake.setPrice(PRICE + 0.1 ether);
        bytes32 requestId = _ask(id);
        assertEq(_bond(id), BOND - (PRICE + 0.1 ether));
        assertEq(imd.balanceOf(payee), PRICE + 0.1 ether);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Asked));

        _answer(id, requestId, MAX_OUT + 1);
        vault.payout(id);
        uint256 left = BOND - (PRICE + 0.1 ether);
        assertEq(imd.balanceOf(watcher), left / 10, "the verdict was bought and paid out");
        assertEq(imd.balanceOf(maker), 100 ether - BOND);
    }

    function test_APriceAboveWhatIsLeftOfTheBondIsStillRefused() public {
        uint256 id = _make();
        _close(id);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());
        intake.setPrice(BOND + 1);
        vm.prank(watcher);
        vm.expectRevert(PinkyVault.InvalidPayment.selector);
        vault.ask(id);

        intake.setPrice(BOND);
        vm.prank(watcher);
        vault.ask(id);
        assertEq(_bond(id), 0);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    /// @dev Review finding: `ask` refuses a zero price for ever, so `make` must refuse one too or
    /// the promise can only ever be refunded in full.
    function test_MakeRefusesAPromiseWhileTheIntakeQuotesZero() public {
        vm.prank(owner);
        vault.setProtocol(address(intake), bytes32("oracle.request@oracle-2"));
        intake.setPrice(0);
        vm.prank(maker);
        vm.expectRevert(PinkyVault.InvalidPayment.selector);
        vault.make(address(token), MAX_OUT, 1 hours, BOND);
        assertEq(vault.count(), 0);
        assertEq(imd.balanceOf(maker), 100 ether);

        intake.setPrice(PRICE);
        vm.prank(maker);
        uint256 id = vault.make(address(token), MAX_OUT, 1 hours, BOND);
        _close(id);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());
        intake.setPrice(0);
        vm.expectRevert(PinkyVault.InvalidPayment.selector);
        vault.ask(id);
    }

    function test_RefundAfterThreeUnansweredAttempts() public {
        uint256 id = _make();
        _close(id);
        for (uint256 i; i < 3; ++i) {
            _ask(id);
            vm.expectRevert(PinkyVault.TooEarly.selector);
            vault.refund(id);
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
        vm.expectRevert(PinkyVault.NoAttemptsLeft.selector);
        vault.ask(id);

        vault.refund(id);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Refunded));
        assertEq(imd.balanceOf(maker), 100 ether - 3 * PRICE);
        assertEq(imd.balanceOf(address(vault)), 0);
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.refund(id);
    }

    function test_RefundAfterTheGraceWhenNobodyAsked() public {
        uint256 id = _make();
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.refund(id);
        _close(id);
        vm.expectRevert(PinkyVault.TooEarly.selector);
        vault.refund(id);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.refund(id);
        assertEq(imd.balanceOf(maker), 100 ether);
    }

    function test_ALateAnswerStillCountsUntilSomeoneMovesOn() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        _answer(id, requestId, MAX_OUT + 1);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Broken));
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.refund(id);
    }

    // ───────────────────────── owner ─────────────────────────

    function test_OnlyTheOwnerChangesSettings() public {
        vm.expectRevert(PinkyVault.OnlyOwner.selector);
        vault.setSigner(address(1));
        vm.expectRevert(PinkyVault.OnlyOwner.selector);
        vault.setProtocol(address(1), ACTION);
        vm.expectRevert(PinkyVault.OnlyOwner.selector);
        vault.setPanel(5, 5, 3_600);

        vm.startPrank(owner);
        vault.setSigner(address(1));
        assertEq(vault.oracleSigner(), address(1));
        vault.setPanel(7, 5, 3_600);
        assertEq(vault.panelSize(), 7);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        vault.setPanel(5, 6, 3_600);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        vault.setProtocol(address(0), ACTION);
        vm.stopPrank();
    }

    // ───────────────────────── fuzz ─────────────────────────

    function testFuzz_EveryPathLeavesTheVaultEmpty(uint256 bond, uint256 maxOut, uint256 out, bool staked) public {
        bond = bound(bond, MIN_BOND, 100 ether);
        if (staked) {
            pinky.mint(staker, 1 ether);
            vm.startPrank(staker);
            pinky.approve(address(staking), 1 ether);
            staking.stake(1 ether);
            vm.stopPrank();
        }
        vm.prank(maker);
        uint256 id = vault.make(address(token), maxOut, 1 hours, bond);
        _close(id);
        bytes32 requestId = _ask(id);
        _answer(id, requestId, out);
        vault.payout(id);

        assertEq(imd.balanceOf(address(vault)), 0);
        uint256 left = bond - PRICE;
        if (out <= maxOut) {
            assertEq(imd.balanceOf(maker), 100 ether - PRICE);
        } else {
            assertEq(imd.balanceOf(watcher) + imd.balanceOf(address(staking)) + imd.balanceOf(vault.BURN()), left);
        }
    }
}
