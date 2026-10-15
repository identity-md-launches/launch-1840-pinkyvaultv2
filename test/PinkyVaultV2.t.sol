// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {PinkyVaultV2} from "../src/PinkyVaultV2.sol";
import {PinkyStaking} from "../src/PinkyStaking.sol";
import {MockERC20, MockIntake} from "./mocks/Mocks.sol";

contract PinkyVaultV2Test is Test {
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");
    uint256 constant PRICE = 0.5 ether;
    uint256 constant MIN_BOND = 5 ether;
    uint256 constant BOND = 10 ether;
    uint256 constant AMOUNT = 1_000 ether;
    uint256 constant SIGNER_PK = 0xA11CE;

    MockERC20 imd;
    MockERC20 pinky;
    MockERC20 token;
    MockIntake intake;
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
        intake = new MockIntake(payee, PRICE);
        staking = new PinkyStaking(address(pinky), address(imd));
        vault = new PinkyVaultV2(
            owner, address(imd), address(staking), address(intake), ACTION, signer, MIN_BOND, 7, 5, 86_400
        );
        imd.mint(maker, 100 ether);
        vm.prank(maker);
        imd.approve(address(vault), type(uint256).max);
    }

    // ───────────────────────── helpers ─────────────────────────

    function _make(PinkyVaultV2.Kind kind, address target, address beneficiary) internal returns (uint256 id) {
        vm.prank(maker);
        id = vault.make(kind, address(token), AMOUNT, target, beneficiary, 1 hours, BOND);
    }

    function _keep() internal returns (uint256) {
        return _make(PinkyVaultV2.Kind.Keep, address(0), address(0));
    }

    /// @dev Past the deadline and the grace, with blocks moving at Robinhood Chain's pace.
    function _due() internal {
        vm.warp(vm.getBlockTimestamp() + 1 hours + vault.CLOSE_GRACE());
        vm.roll(vm.getBlockNumber() + 37_200);
    }

    function _settle(uint256 id) internal returns (bytes32 requestId) {
        _due();
        vm.prank(watcher);
        requestId = vault.settle(id);
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

    function _attestation(uint256 id, uint8 answerType, bytes memory answer, uint256 figure)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        (uint64 startBlock, uint64 endBlock) = _window(id);
        a.requestId = bytes32(bytes16(keccak256(abi.encode(id, figure, answer))));
        a.chainId = block.chainid;
        a.questionHash = keccak256("q");
        a.answerType = answerType;
        a.answer = answer;
        a.figure = figure;
        a.fromBlock = startBlock;
        a.toBlock = endBlock;
        a.blockHash = keccak256("b");
        a.panelJobId = keccak256("p");
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 5;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 86_400);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, vault.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _answerUint(uint256 id, bytes32 requestId, uint256 out) internal {
        OracleAttestation.Attestation memory a = _attestation(id, 3, abi.encode(out), out);
        intake.complete(requestId, a, _sign(a));
    }

    function _answerBool(uint256 id, bytes32 requestId, bool yes, uint256 balance) internal {
        OracleAttestation.Attestation memory a = _attestation(id, 0, abi.encode(yes), balance);
        intake.complete(requestId, a, _sign(a));
    }

    function _stake() internal {
        pinky.mint(staker, 1_000 ether);
        vm.startPrank(staker);
        pinky.approve(address(staking), type(uint256).max);
        staking.stake(1_000 ether);
        vm.stopPrank();
    }

    // ───────────────────────── make ─────────────────────────

    function test_MakeRecordsEveryKind() public {
        uint256 a = _keep();
        uint256 b = _make(PinkyVaultV2.Kind.Pay, friend, friend);
        uint256 c = _make(PinkyVaultV2.Kind.Hold, address(0), friend);
        uint256 d = _make(PinkyVaultV2.Kind.Moves, address(0), address(0));
        assertEq(vault.count(), 4);
        assertEq(imd.balanceOf(address(vault)), 4 * BOND);
        (address m, address t, PinkyVaultV2.Kind kind,,,, uint256 amount, address target, address beneficiary,,,,,,,,,,,)
        = vault.promises(b);
        assertEq(m, maker);
        assertEq(t, address(token));
        assertEq(uint8(kind), uint8(PinkyVaultV2.Kind.Pay));
        assertEq(amount, AMOUNT);
        assertEq(target, friend);
        assertEq(beneficiary, friend);
        (a, c, d);
    }

    function test_MakeRefusesWhatCannotBeJudged() public {
        vm.startPrank(maker);
        // Pay needs someone else to pay, and something to pay.
        vm.expectRevert(PinkyVaultV2.InvalidPromise.selector);
        vault.make(PinkyVaultV2.Kind.Pay, address(token), AMOUNT, address(0), address(0), 1 hours, BOND);
        vm.expectRevert(PinkyVaultV2.InvalidPromise.selector);
        vault.make(PinkyVaultV2.Kind.Pay, address(token), AMOUNT, maker, address(0), 1 hours, BOND);
        vm.expectRevert(PinkyVaultV2.InvalidPromise.selector);
        vault.make(PinkyVaultV2.Kind.Pay, address(token), AMOUNT, address(vault), address(0), 1 hours, BOND);
        vm.expectRevert(PinkyVaultV2.InvalidPromise.selector);
        vault.make(PinkyVaultV2.Kind.Pay, address(token), 0, friend, address(0), 1 hours, BOND);
        // A target means nothing outside Pay.
        vm.expectRevert(PinkyVaultV2.InvalidPromise.selector);
        vault.make(PinkyVaultV2.Kind.Keep, address(token), AMOUNT, friend, address(0), 1 hours, BOND);
        // The bond leaves as IMD inside the window, so Keep and Moves cannot be about IMD.
        vm.expectRevert(PinkyVaultV2.InvalidPromise.selector);
        vault.make(PinkyVaultV2.Kind.Keep, address(imd), AMOUNT, address(0), address(0), 1 hours, BOND);
        vm.expectRevert(PinkyVaultV2.InvalidPromise.selector);
        vault.make(PinkyVaultV2.Kind.Moves, address(imd), 0, address(0), address(0), 1 hours, BOND);
        // Holding at least nothing is always true.
        vm.expectRevert(PinkyVaultV2.InvalidPromise.selector);
        vault.make(PinkyVaultV2.Kind.Hold, address(token), 0, address(0), address(0), 1 hours, BOND);
        // Nobody makes a promise to themselves.
        vm.expectRevert(PinkyVaultV2.InvalidPromise.selector);
        vault.make(PinkyVaultV2.Kind.Keep, address(token), AMOUNT, address(0), maker, 1 hours, BOND);
        vm.expectRevert(PinkyVaultV2.InvalidPromise.selector);
        vault.make(PinkyVaultV2.Kind.Keep, makeAddr("not a contract"), AMOUNT, address(0), address(0), 1 hours, BOND);
        vm.expectRevert(PinkyVaultV2.InvalidPromise.selector);
        vault.make(PinkyVaultV2.Kind.Keep, address(token), AMOUNT, address(0), address(0), 9 minutes, BOND);
        vm.expectRevert(PinkyVaultV2.BondTooSmall.selector);
        vault.make(PinkyVaultV2.Kind.Keep, address(token), AMOUNT, address(0), address(0), 1 hours, 4 ether);
        vm.stopPrank();
    }

    function test_HoldMayBeAboutImd() public {
        vm.prank(maker);
        vault.make(PinkyVaultV2.Kind.Hold, address(imd), 1 ether, address(0), address(0), 1 hours, BOND);
        vm.prank(maker);
        vault.make(PinkyVaultV2.Kind.Pay, address(imd), 1 ether, friend, friend, 1 hours, BOND);
    }

    function test_MakeRefusesWhileTheOracleSellsNothing() public {
        intake.setPrice(0);
        vm.prank(maker);
        vm.expectRevert(PinkyVaultV2.InvalidPayment.selector);
        vault.make(PinkyVaultV2.Kind.Keep, address(token), AMOUNT, address(0), address(0), 1 hours, BOND);
    }

    // ───────────────────────── settle ─────────────────────────

    function test_SettleClosesThirtyTwoBlocksBackAndAsksAtOnce() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        (uint64 startBlock, uint64 endBlock) = _window(id);
        assertEq(startBlock, 1_000);
        assertEq(endBlock, vm.getBlockNumber() - 32);
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Asked));
        assertEq(_bond(id), BOND - PRICE);
        assertEq(imd.balanceOf(payee), PRICE);
        assertEq(vault.promiseIdFor(address(intake), requestId), id);
    }

    function test_SettleWaitsForTheGrace() public {
        uint256 id = _keep();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 36_000);
        vm.expectRevert(PinkyVaultV2.TooEarly.selector);
        vault.settle(id);
        vm.warp(vm.getBlockTimestamp() + vault.CLOSE_GRACE() - 1);
        vm.expectRevert(PinkyVaultV2.TooEarly.selector);
        vault.settle(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        vault.settle(id);
    }

    function test_SettleUsesTheArbitrumBlockNumber() public {
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(uint256(84_000_000)));
        uint256 id = _keep();
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(uint256(84_040_000)));
        _settle(id);
        (uint64 startBlock, uint64 endBlock) = _window(id);
        assertEq(startBlock, 84_000_000);
        assertEq(endBlock, 84_039_968);
    }

    function test_CloseAloneThenAsk() public {
        uint256 id = _keep();
        _due();
        vault.close(id);
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Closed));
        vm.prank(watcher);
        vault.ask(id);
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Asked));
    }

    // ───────────────────────── the questions ─────────────────────────

    function _recipe(uint256 id, bytes32 requestId) internal view returns (string memory body, string memory recipe) {
        body = string(intake.bodyOf(requestId));
        assertEq(body, vault.bodyOf(id));
        string memory full = vm.parseJsonString(body, ".definitions.recipe");
        // "{...} - write recipe exactly this, event text included."
        bytes memory raw = bytes(full);
        uint256 end;
        for (uint256 i; i < raw.length; i++) {
            if (raw[i] == "}" && (i + 1 == raw.length || raw[i + 1] == " ")) end = i + 1;
        }
        bytes memory out = new bytes(end);
        for (uint256 i; i < end; i++) {
            out[i] = raw[i];
        }
        recipe = string(out);
    }

    function test_KeepAsksTheFirstVaultsQuestion() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        (string memory body, string memory recipe) = _recipe(id, requestId);
        assertEq(vm.parseJsonString(body, ".answerType"), "uint256");
        assertEq(vm.parseJsonString(recipe, ".kind"), "log-sum");
        assertEq(vm.parseJsonString(recipe, ".sumArg"), "value");
        assertEq(vm.parseJsonAddress(recipe, ".filter.from"), maker);
        assertFalse(vm.keyExistsJson(recipe, ".filter.to"));
        (uint64 startBlock, uint64 endBlock) = _window(id);
        assertEq(vm.parseJsonUint(body, ".window.fromBlock"), startBlock);
        assertEq(vm.parseJsonUint(body, ".window.toBlock"), endBlock);
        assertEq(vm.parseJsonUint(body, ".panelSize"), 7);
        assertEq(vm.parseJsonUint(body, ".quorum"), 5);
    }

    function test_PayFiltersOnBothEnds() public {
        uint256 id = _make(PinkyVaultV2.Kind.Pay, friend, friend);
        bytes32 requestId = _settle(id);
        (string memory body, string memory recipe) = _recipe(id, requestId);
        assertEq(vm.parseJsonString(body, ".answerType"), "uint256");
        assertEq(vm.parseJsonString(recipe, ".kind"), "log-sum");
        assertEq(vm.parseJsonAddress(recipe, ".filter.from"), maker);
        assertEq(vm.parseJsonAddress(recipe, ".filter.to"), friend);
    }

    function test_HoldAsksForABalanceAtTheEnd() public {
        uint256 id = _make(PinkyVaultV2.Kind.Hold, address(0), address(0));
        bytes32 requestId = _settle(id);
        (string memory body, string memory recipe) = _recipe(id, requestId);
        assertEq(vm.parseJsonString(body, ".answerType"), "bool");
        assertEq(vm.parseJsonString(recipe, ".kind"), "call-compare");
        assertEq(vm.parseJsonAddress(recipe, ".to"), address(token));
        assertEq(vm.parseJsonString(recipe, ".function"), "function balanceOf(address) view returns (uint256)");
        assertEq(vm.parseJsonString(recipe, ".op"), ">=");
        assertEq(vm.parseJsonString(recipe, ".threshold"), vm.toString(AMOUNT));
        address[] memory args = vm.parseJsonAddressArray(recipe, ".args");
        assertEq(args.length, 1);
        assertEq(args[0], maker);
    }

    function test_MovesCountsTransfersOut() public {
        uint256 id = _make(PinkyVaultV2.Kind.Moves, address(0), address(0));
        bytes32 requestId = _settle(id);
        (string memory body, string memory recipe) = _recipe(id, requestId);
        assertEq(vm.parseJsonString(body, ".answerType"), "uint256");
        assertEq(vm.parseJsonString(recipe, ".kind"), "log-count");
        assertEq(
            vm.parseJsonString(recipe, ".event"),
            "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)"
        );
        assertEq(vm.parseJsonAddress(recipe, ".filter.from"), maker);
    }

    /// The exact recipe the oracle attested on 2026-10-14 for a two-sided filter, key for key.
    function test_PayRecipeMatchesTheLiveTest() public {
        uint256 id = _make(PinkyVaultV2.Kind.Pay, friend, address(0));
        bytes32 requestId = _settle(id);
        (, string memory recipe) = _recipe(id, requestId);
        string memory expected = string.concat(
            '{"kind":"log-sum","address":"',
            vm.toLowercase(vm.toString(address(token))),
            '","event":"event Transfer(address indexed from, address indexed to, uint256 value)","sumArg":"value","abs":false,"filter":{"from":"',
            vm.toLowercase(vm.toString(maker)),
            '","to":"',
            vm.toLowercase(vm.toString(friend)),
            '"}}'
        );
        assertEq(recipe, expected);
    }

    // ───────────────────────── verdicts ─────────────────────────

    function test_KeepAndMovesAreKeptAtTheLimitAndBrokenAbove() public {
        uint256 a = _keep();
        uint256 b = _keep();
        uint256 c = _make(PinkyVaultV2.Kind.Moves, address(0), address(0));
        _due();
        bytes32 ra = vault.settle(a);
        bytes32 rb = vault.settle(b);
        bytes32 rc = vault.settle(c);
        _answerUint(a, ra, AMOUNT);
        _answerUint(b, rb, AMOUNT + 1);
        _answerUint(c, rc, AMOUNT + 1);
        assertEq(uint8(_status(a)), uint8(PinkyVaultV2.Status.Kept));
        assertEq(uint8(_status(b)), uint8(PinkyVaultV2.Status.Broken));
        assertEq(uint8(_status(c)), uint8(PinkyVaultV2.Status.Broken));
    }

    function test_PayIsKeptAtTheAmountAndBrokenBelow() public {
        uint256 a = _make(PinkyVaultV2.Kind.Pay, friend, friend);
        uint256 b = _make(PinkyVaultV2.Kind.Pay, friend, friend);
        _due();
        bytes32 ra = vault.settle(a);
        bytes32 rb = vault.settle(b);
        _answerUint(a, ra, AMOUNT);
        _answerUint(b, rb, AMOUNT - 1);
        assertEq(uint8(_status(a)), uint8(PinkyVaultV2.Status.Kept));
        assertEq(uint8(_status(b)), uint8(PinkyVaultV2.Status.Broken));
    }

    function test_HoldTakesABoolAndKeepsTheBalance() public {
        uint256 a = _make(PinkyVaultV2.Kind.Hold, address(0), address(0));
        uint256 b = _make(PinkyVaultV2.Kind.Hold, address(0), address(0));
        _due();
        bytes32 ra = vault.settle(a);
        bytes32 rb = vault.settle(b);
        _answerBool(a, ra, true, 2_000 ether);
        _answerBool(b, rb, false, 3 ether);
        assertEq(uint8(_status(a)), uint8(PinkyVaultV2.Status.Kept));
        assertEq(uint8(_status(b)), uint8(PinkyVaultV2.Status.Broken));
        (,,,,,,,,,,,,,,,,,, uint256 observed,) = vault.promises(b);
        assertEq(observed, 3 ether);
    }

    function test_AnswerOfTheWrongTypeIsRefused() public {
        uint256 hold = _make(PinkyVaultV2.Kind.Hold, address(0), address(0));
        uint256 keep = _keep();
        _due();
        bytes32 rh = vault.settle(hold);
        bytes32 rk = vault.settle(keep);
        OracleAttestation.Attestation memory a = _attestation(hold, 3, abi.encode(uint256(1)), 1);
        bytes memory sig = _sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, 0, 3));
        intake.complete(rh, a, sig);
        a = _attestation(keep, 0, abi.encode(true), 0);
        sig = _sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, 3, 0));
        intake.complete(rk, a, sig);
    }

    function test_AnswerForOtherBlocksOrAWeakPanelIsRefused() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        OracleAttestation.Attestation memory a = _attestation(id, 3, abi.encode(uint256(0)), 0);
        a.toBlock += 1;
        bytes memory sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);
        a = _attestation(id, 3, abi.encode(uint256(0)), 0);
        a.agreed = 4;
        sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);
        a = _attestation(id, 3, abi.encode(uint256(0)), 0);
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);
        a = _attestation(id, 3, abi.encode(uint256(0)), 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, vault.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, abi.encodePacked(r, s, v));
    }

    // ───────────────────────── payouts ─────────────────────────

    function test_KeptPaysTheMakerLessOnePercent() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        _answerUint(id, requestId, 0);
        uint256 before = imd.balanceOf(maker);
        vault.payout(id);
        uint256 left = BOND - PRICE;
        uint256 fee = left / 100;
        assertEq(imd.balanceOf(maker) - before, left - fee);
        assertEq(vault.fees(), fee);
        assertEq(imd.balanceOf(address(vault)), fee);
        vm.expectRevert(PinkyVaultV2.AlreadyPaid.selector);
        vault.payout(id);
    }

    function test_BrokenToABeneficiaryPaysThemLessOnePercent() public {
        uint256 id = _make(PinkyVaultV2.Kind.Pay, friend, friend);
        bytes32 requestId = _settle(id);
        _answerUint(id, requestId, 0);
        vault.payout(id);
        uint256 left = BOND - PRICE;
        uint256 fee = left / 100;
        assertEq(imd.balanceOf(friend), left - fee);
        assertEq(imd.balanceOf(watcher), 0);
        assertEq(imd.balanceOf(vault.BURN()), 0);
        assertEq(vault.fees(), fee);
    }

    function test_KeptToABeneficiaryStillGoesHome() public {
        uint256 id = _make(PinkyVaultV2.Kind.Keep, address(0), friend);
        bytes32 requestId = _settle(id);
        _answerUint(id, requestId, 0);
        uint256 before = imd.balanceOf(maker);
        vault.payout(id);
        uint256 left = BOND - PRICE;
        assertEq(imd.balanceOf(maker) - before, left - left / 100);
        assertEq(imd.balanceOf(friend), 0);
    }

    function test_BrokenToNobodyIsSplitWithoutAFee() public {
        _stake();
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        _answerUint(id, requestId, AMOUNT + 1);
        vault.payout(id);
        uint256 left = BOND - PRICE;
        uint256 bounty = left / 10;
        uint256 toStakers = (left - bounty) / 2;
        assertEq(imd.balanceOf(watcher), bounty);
        assertEq(imd.balanceOf(address(staking)), toStakers);
        assertEq(imd.balanceOf(vault.BURN()), left - bounty - toStakers);
        assertEq(vault.fees(), 0);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_MakerWhoAsksEarnsNoBounty() public {
        uint256 id = _keep();
        _due();
        vm.prank(maker);
        bytes32 requestId = vault.settle(id);
        _answerUint(id, requestId, AMOUNT + 1);
        vault.payout(id);
        // Nobody is staked, so all of it burns.
        assertEq(imd.balanceOf(vault.BURN()), BOND - PRICE);
    }

    function test_RefundAfterThreeUnansweredAsksTakesNoFee() public {
        uint256 id = _keep();
        _settle(id);
        for (uint256 i; i < 2; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            vault.ask(id);
        }
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(PinkyVaultV2.NoAttemptsLeft.selector);
        vault.ask(id);
        uint256 before = imd.balanceOf(maker);
        vault.refund(id);
        assertEq(imd.balanceOf(maker) - before, BOND - 3 * PRICE);
        assertEq(vault.fees(), 0);
    }

    function test_AnEarlierRequestStillCounts() public {
        uint256 id = _keep();
        bytes32 first = _settle(id);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.ask(id);
        _answerUint(id, first, 0);
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Kept));
    }

    // ───────────────────────── failures ─────────────────────────

    function test_AFailureLetsAnyoneAskAgainAtOnce() public {
        uint256 id = _keep();
        bytes32 first = _settle(id);
        vm.expectRevert(PinkyVaultV2.TooEarly.selector);
        vault.ask(id);
        intake.fail(first, 2, bytes32("disagreed"));
        bytes32 second = vault.ask(id);
        assertTrue(second != first);
        assertEq(_bond(id), BOND - 2 * PRICE);
        _answerUint(id, second, 0);
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Kept));
    }

    function test_AFailureMovesNoMoneyAndRefundsStillWait() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        uint256 vaultBefore = imd.balanceOf(address(vault));
        intake.fail(requestId, 1, bytes32("refused"));
        assertEq(imd.balanceOf(address(vault)), vaultBefore);
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Asked));
        vm.expectRevert(PinkyVaultV2.TooEarly.selector);
        vault.refund(id);
        // Three failures in a row: the refund still waits out the last day, as without reports.
        bytes32 r2 = vault.ask(id);
        intake.fail(r2, 2, bytes32("failed"));
        bytes32 r3 = vault.ask(id);
        intake.fail(r3, 2, bytes32("failed"));
        vm.expectRevert(PinkyVaultV2.NoAttemptsLeft.selector);
        vault.ask(id);
        vm.expectRevert(PinkyVaultV2.TooEarly.selector);
        vault.refund(id);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 before = imd.balanceOf(maker);
        vault.refund(id);
        assertEq(imd.balanceOf(maker) - before, BOND - 3 * PRICE);
    }

    function test_AFailedRequestCannotBeAnsweredAfterwards() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        intake.fail(requestId, 2, bytes32("disagreed"));
        OracleAttestation.Attestation memory a = _attestation(id, 3, abi.encode(uint256(0)), 0);
        bytes memory sig = _sign(a);
        vm.expectRevert(PinkyVaultV2.UnknownRequest.selector);
        intake.complete(requestId, a, sig);
    }

    function test_OnlyTheIntakeReportsAndOnlyForItsOwnRequests() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        vm.expectRevert(PinkyVaultV2.UnknownRequest.selector);
        vault.onOracleFailure(requestId, 2, bytes32("failed"), 0, 0, "");
        vm.prank(address(intake));
        vm.expectRevert(PinkyVaultV2.UnknownRequest.selector);
        vault.onOracleFailure(keccak256("someone else's"), 2, bytes32("failed"), 0, 0, "");
        // A report about an earlier request does not unlock asking again.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        bytes32 second = vault.ask(id);
        intake.fail(requestId, 2, bytes32("failed"));
        vm.expectRevert(PinkyVaultV2.TooEarly.selector);
        vault.ask(id);
        _answerUint(id, second, 0);
        assertEq(uint8(_status(id)), uint8(PinkyVaultV2.Status.Kept));
    }

    function test_AFailureReportFitsTheIntakesGas() public {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        assertLt(intake.fail(requestId, 2, bytes32("disagreed")), 60_000);
    }

    // ───────────────────────── fees ─────────────────────────

    function _earnFee() internal returns (uint256 fee) {
        uint256 id = _keep();
        bytes32 requestId = _settle(id);
        _answerUint(id, requestId, 0);
        vault.payout(id);
        fee = vault.fees();
    }

    function test_FeesGoToStakers() public {
        uint256 fee = _earnFee();
        _stake();
        vault.sendFees();
        assertEq(vault.fees(), 0);
        assertEq(imd.balanceOf(address(staking)), fee);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_FeesWaitWhileNobodyIsStaked() public {
        uint256 fee = _earnFee();
        vault.sendFees();
        assertEq(vault.fees(), fee);
        assertEq(imd.balanceOf(address(vault)), fee);
        assertEq(imd.allowance(address(vault), address(staking)), 0);
        _stake();
        vault.sendFees();
        assertEq(imd.balanceOf(address(staking)), fee);
    }

    function test_SendingFeesNeverTouchesBonds() public {
        _earnFee();
        _keep();
        _stake();
        vault.sendFees();
        assertEq(imd.balanceOf(address(vault)), BOND);
    }

    // ───────────────────────── settings ─────────────────────────

    function test_OnlyTheOwnerProposes() public {
        vm.expectRevert(PinkyVaultV2.OnlyOwner.selector);
        vault.proposeSigner(makeAddr("new signer"));
        vm.expectRevert(PinkyVaultV2.OnlyOwner.selector);
        vault.cancel(PinkyVaultV2.Setting.Signer);
    }

    function test_SignerChangesOnlyAfterAWeek() public {
        address next = makeAddr("new signer");
        vm.prank(owner);
        vault.proposeSigner(next);
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        vm.expectRevert(PinkyVaultV2.TooEarly.selector);
        vault.enact(PinkyVaultV2.Setting.Signer);
        assertEq(vault.oracleSigner(), signer);
        vm.warp(vm.getBlockTimestamp() + 1);
        vault.enact(PinkyVaultV2.Setting.Signer);
        assertEq(vault.oracleSigner(), next);
        vm.expectRevert(PinkyVaultV2.NothingPending.selector);
        vault.enact(PinkyVaultV2.Setting.Signer);
    }

    function test_ProposalsCanBeCancelled() public {
        vm.startPrank(owner);
        vault.proposePanel(9, 7, 3_600);
        vault.cancel(PinkyVaultV2.Setting.Panel);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(PinkyVaultV2.NothingPending.selector);
        vault.enact(PinkyVaultV2.Setting.Panel);
    }

    function test_PanelProtocolAndSinkTakeEffectAfterTheDelay() public {
        MockIntake other = new MockIntake(payee, PRICE);
        PinkyStaking sink = new PinkyStaking(address(pinky), address(imd));
        vm.startPrank(owner);
        vault.proposePanel(9, 7, 3_600);
        vault.proposeProtocol(address(other), bytes32("oracle.request@oracle-2"));
        vault.proposeFeeSink(address(sink));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.enact(PinkyVaultV2.Setting.Panel);
        vault.enact(PinkyVaultV2.Setting.Protocol);
        vault.enact(PinkyVaultV2.Setting.FeeSink);
        assertEq(vault.panelSize(), 9);
        assertEq(vault.quorum(), 7);
        assertEq(vault.validForSeconds(), 3_600);
        assertEq(address(vault.intake()), address(other));
        assertEq(vault.action(), bytes32("oracle.request@oracle-2"));
        assertEq(address(vault.feeSink()), address(sink));
    }

    function test_BadProposalsAreRefusedUpFront() public {
        vm.startPrank(owner);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        vault.proposePanel(5, 6, 3_600);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        vault.proposeSigner(address(0));
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        vault.proposeProtocol(address(0), ACTION);
        vm.expectRevert(PinkyVaultV2.InvalidConfiguration.selector);
        vault.proposeFeeSink(makeAddr("not a contract"));
        vm.stopPrank();
    }

    /// A promise made before a protocol change is held to the price it was made under.
    function test_ANewIntakeCannotChargeOldPromisesMore() public {
        uint256 id = _keep();
        MockIntake greedy = new MockIntake(payee, 2 ether);
        vm.prank(owner);
        vault.proposeProtocol(address(greedy), ACTION);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.enact(PinkyVaultV2.Setting.Protocol);
        vm.roll(vm.getBlockNumber() + 40_000);
        vm.expectRevert(PinkyVaultV2.InvalidPayment.selector);
        vault.settle(id);
    }

    // ───────────────────────── the Intake's gas ─────────────────────────

    /// The real Intake hands the callback 200,000 gas; every kind's verdict must fit with room.
    function test_EveryVerdictFitsTheIntakesGas() public {
        uint256[4] memory ids = [
            _keep(),
            _make(PinkyVaultV2.Kind.Pay, friend, friend),
            _make(PinkyVaultV2.Kind.Hold, address(0), address(0)),
            _make(PinkyVaultV2.Kind.Moves, address(0), address(0))
        ];
        _due();
        for (uint256 i; i < 4; i++) {
            bytes32 requestId = vault.settle(ids[i]);
            OracleAttestation.Attestation memory a = i == 2
                ? _attestation(ids[i], 0, abi.encode(true), AMOUNT)
                : _attestation(ids[i], 3, abi.encode(uint256(0)), 0);
            uint256 used = intake.complete(requestId, a, _sign(a));
            assertLt(used, 150_000);
        }
    }

    // ───────────────────────── fuzz ─────────────────────────

    /// Whatever the outcome, every wei of a bond ends with the maker, the beneficiary, the watcher,
    /// stakers, the burn, the oracle or the fee pot.
    function testFuzz_BondIsAccountedFor(uint8 kindRaw, bool toFriend, uint256 out, bool staked) public {
        PinkyVaultV2.Kind kind = PinkyVaultV2.Kind(bound(kindRaw, 0, 3));
        if (staked) _stake();
        address target = kind == PinkyVaultV2.Kind.Pay ? friend : address(0);
        uint256 id = _make(kind, target, toFriend ? friend : address(0));
        bytes32 requestId = _settle(id);
        out = bound(out, 0, 2 * AMOUNT);
        if (kind == PinkyVaultV2.Kind.Hold) _answerBool(id, requestId, out >= AMOUNT, out);
        else _answerUint(id, requestId, out);
        uint256 makerBefore = imd.balanceOf(maker);
        vault.payout(id);
        uint256 total = (imd.balanceOf(maker) - makerBefore) + imd.balanceOf(friend) + imd.balanceOf(watcher)
            + imd.balanceOf(address(staking)) + imd.balanceOf(vault.BURN()) + imd.balanceOf(payee) + vault.fees();
        assertEq(total, BOND);
        assertEq(imd.balanceOf(address(vault)), vault.fees());
    }
}
