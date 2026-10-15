// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {PinkyVault} from "../src/PinkyVault.sol";
import {PinkyStaking} from "../src/PinkyStaking.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {
    FeeOnTransferERC20,
    StipendIntake,
    RevertingIntake,
    BrokenQuoteIntake,
    ShortPullIntake,
    NoPullIntake,
    FixedIdIntake
} from "./mocks/MoreMocks.sol";
import {PinkyFixture} from "./utils/PinkyFixture.sol";

/// @notice The inputs the vault was not written for: zero, the exact boundary, the same call
/// twice, an Intake that misbehaves, a callback from the wrong place, an attestation that is
/// stale, tampered, oversized or signed for a neighbour.
contract PinkyVaultEdgesTest is PinkyFixture {
    // ───────────────────────── constructor ─────────────────────────

    function _deploy(
        address owner_,
        address imd_,
        address staking_,
        address intake_,
        bytes32 action_,
        address signer_,
        uint256 minBond_,
        uint16 panel_,
        uint16 quorum_,
        uint32 validFor_
    ) internal returns (PinkyVault) {
        return new PinkyVault(owner_, imd_, staking_, intake_, action_, signer_, minBond_, panel_, quorum_, validFor_);
    }

    function test_ConstructorRefusesEveryZero() public {
        address i = address(intake);
        address s = address(staking);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        _deploy(address(0), address(imd), s, i, ACTION, signer, MIN_BOND, PANEL, QUORUM, VALID_FOR);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        _deploy(owner, address(0), s, i, ACTION, signer, MIN_BOND, PANEL, QUORUM, VALID_FOR);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        _deploy(owner, address(imd), address(0), i, ACTION, signer, MIN_BOND, PANEL, QUORUM, VALID_FOR);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        _deploy(owner, address(imd), s, address(0), ACTION, signer, MIN_BOND, PANEL, QUORUM, VALID_FOR);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        _deploy(owner, address(imd), s, i, bytes32(0), signer, MIN_BOND, PANEL, QUORUM, VALID_FOR);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        _deploy(owner, address(imd), s, i, ACTION, signer, 0, PANEL, QUORUM, VALID_FOR);
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        _deploy(owner, address(imd), s, i, ACTION, address(0), MIN_BOND, PANEL, QUORUM, VALID_FOR);
    }

    function test_ConstructorPanelBoundaries() public {
        address i = address(intake);
        address s = address(staking);
        // The smallest and the largest panel the vault accepts.
        PinkyVault small = _deploy(owner, address(imd), s, i, ACTION, signer, 1, 2, 2, 60);
        assertEq(small.panelSize(), 2);
        assertEq(small.quorum(), 2);
        assertEq(small.validForSeconds(), 60);
        PinkyVault large = _deploy(owner, address(imd), s, i, ACTION, signer, 1, 100, 100, 30 days);
        assertEq(large.panelSize(), 100);
        assertEq(large.validForSeconds(), 30 days);

        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        _deploy(owner, address(imd), s, i, ACTION, signer, 1, 1, 1, 60);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        _deploy(owner, address(imd), s, i, ACTION, signer, 1, 101, 2, 60);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        _deploy(owner, address(imd), s, i, ACTION, signer, 1, 7, 1, 60);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        _deploy(owner, address(imd), s, i, ACTION, signer, 1, 7, 8, 60);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        _deploy(owner, address(imd), s, i, ACTION, signer, 1, 7, 5, 59);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        _deploy(owner, address(imd), s, i, ACTION, signer, 1, 7, 5, 30 days + 1);
    }

    function test_ConstructorRecordsTheLaunchArguments() public view {
        assertEq(vault.owner(), owner);
        assertEq(address(vault.imd()), address(imd));
        assertEq(address(vault.staking()), address(staking));
        assertEq(address(vault.intake()), address(intake));
        assertEq(vault.action(), ACTION);
        assertEq(vault.action(), 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000);
        assertEq(vault.oracleSigner(), signer);
        assertEq(vault.minBond(), MIN_BOND);
        assertEq(vault.panelSize(), PANEL);
        assertEq(vault.quorum(), QUORUM);
        assertEq(vault.validForSeconds(), VALID_FOR);
        assertEq(vault.count(), 0);
    }

    // ───────────────────────── make ─────────────────────────

    function test_MakeAcceptsTheExactBoundaries() public {
        vm.startPrank(maker);
        uint256 a = vault.make(address(token), 0, vault.MIN_DURATION(), MIN_BOND);
        uint256 b = vault.make(address(token), type(uint256).max, vault.MAX_DURATION(), MIN_BOND);
        vm.stopPrank();
        assertEq(a, 1);
        assertEq(b, 2);
        (,, uint256 maxOutA, uint256 bondA,,, uint64 endTimeA,,,,,,,,,) = vault.promises(a);
        (,, uint256 maxOutB,,,, uint64 endTimeB,,,,,,,,,) = vault.promises(b);
        assertEq(maxOutA, 0);
        assertEq(bondA, MIN_BOND);
        assertEq(endTimeA, vm.getBlockTimestamp() + 10 minutes);
        assertEq(maxOutB, type(uint256).max);
        assertEq(endTimeB, vm.getBlockTimestamp() + 30 days);
        assertEq(imd.balanceOf(address(vault)), 2 * MIN_BOND);
        assertEq(vault.count(), 2);
    }

    function test_MakeNeedsThreeOracleFeesEvenAboveTheMinimumBond() public {
        intake.setPrice(2 ether);
        vm.startPrank(maker);
        vm.expectRevert(PinkyVault.BondTooSmall.selector);
        vault.make(address(token), MAX_OUT, 1 hours, 6 ether - 1);
        uint256 id = vault.make(address(token), MAX_OUT, 1 hours, 6 ether);
        vm.stopPrank();
        (uint256 maxPrice,,, address madeUnder, bytes32 madeFor) = vault.terms(id);
        assertEq(maxPrice, 2 ether);
        assertEq(madeUnder, address(intake));
        assertEq(madeFor, ACTION);
    }

    function test_MakeNeedsAnAllowanceAndABalance() public {
        address stranger = makeAddr("stranger");
        imd.mint(stranger, BOND);
        vm.prank(stranger);
        vm.expectRevert();
        vault.make(address(token), MAX_OUT, 1 hours, BOND);

        vm.startPrank(stranger);
        imd.approve(address(vault), type(uint256).max);
        vm.expectRevert();
        vault.make(address(token), MAX_OUT, 1 hours, BOND + 1);
        vm.stopPrank();
        assertEq(vault.count(), 0);
    }

    function test_MakeRefusesAnImdThatTakesAFee() public {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20(100);
        PinkyVault v = _deploy(
            owner, address(fee), address(staking), address(intake), ACTION, signer, MIN_BOND, PANEL, QUORUM, VALID_FOR
        );
        fee.mint(maker, BOND);
        vm.startPrank(maker);
        fee.approve(address(v), BOND);
        vm.expectRevert(PinkyVault.InvalidPayment.selector);
        v.make(address(token), MAX_OUT, 1 hours, BOND);
        vm.stopPrank();
    }

    function test_MakeRefusesTheVaultAndTheStakingAsTheToken() public {
        // Both have code, so they pass the contract check; neither is IMD, so they are allowed.
        // That is the contract's rule; what matters is that nothing breaks downstream.
        vm.startPrank(maker);
        vault.make(address(vault), 0, 1 hours, BOND);
        vault.make(address(staking), 0, 1 hours, BOND);
        vm.stopPrank();
        assertEq(vault.count(), 2);
    }

    function test_MakeEmitsMade() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit PinkyVault.Made(
            1, maker, address(token), MAX_OUT, BOND, uint64(START_BLOCK), uint64(vm.getBlockTimestamp() + 1 hours)
        );
        _make();
    }

    function test_AQuoteThatDropsToZeroAfterMakeLeavesOnlyTheRefund() public {
        uint256 id = _make();
        intake.setPrice(0);
        _close(id);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());
        vm.expectRevert(PinkyVault.InvalidPayment.selector);
        vault.ask(id);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Closed));
        assertEq(_attempts(id), 0);
        // A quote again, at the price the promise was made under, and the ask goes through.
        intake.setPrice(PRICE);
        vm.prank(watcher);
        vault.ask(id);
        assertEq(_bond(id), BOND - PRICE);

        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE());
        vault.refund(id);
        assertEq(imd.balanceOf(maker), 100 ether - PRICE);
    }

    // ───────────────────────── close ─────────────────────────

    function test_CloseRefusesUnknownIds() public {
        _make();
        vm.expectRevert(PinkyVault.UnknownPromise.selector);
        vault.close(0);
        vm.expectRevert(PinkyVault.UnknownPromise.selector);
        vault.close(2);
    }

    function test_CloseExactlyAtTheDeadline() public {
        uint256 id = _make();
        vm.warp(vm.getBlockTimestamp() + 1 hours - 1);
        vm.expectRevert(PinkyVault.TooEarly.selector);
        vault.close(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PinkyVault.Closed(id, uint64(vm.getBlockNumber()));
        vault.close(id);
        (,,,,, uint64 endBlock,, uint64 closedAt,,,,,,,,) = vault.promises(id);
        assertEq(endBlock, vm.getBlockNumber());
        assertEq(closedAt, vm.getBlockTimestamp());
    }

    function test_AnyoneMayCloseIncludingTheMaker() public {
        uint256 id = _make();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(maker);
        vault.close(id);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Closed));
    }

    // ───────────────────────── ask ─────────────────────────

    function test_AskExactlyAtTheSettleDelay() public {
        uint256 id = _make();
        _close(id);
        (,,,,, uint64 endBlock,,,,,,,,,,) = vault.promises(id);
        vm.roll(uint256(endBlock) + vault.SETTLE_DELAY_BLOCKS() - 1);
        vm.expectRevert(PinkyVault.TooEarly.selector);
        vault.ask(id);
        vm.roll(uint256(endBlock) + vault.SETTLE_DELAY_BLOCKS());
        vm.prank(watcher);
        bytes32 requestId = vault.ask(id);
        assertEq(_asker(id), watcher);
        assertEq(_attempts(id), 1);
        assertEq(vault.promiseIdFor(address(intake), requestId), id);
    }

    function test_AskRefusesSettledPromises() public {
        uint256 kept = _make();
        _close(kept);
        _answer(kept, _ask(kept), 0);
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.ask(kept);
        vault.payout(kept);
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.ask(kept);

        uint256 refunded = _make();
        _close(refunded);
        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE());
        vault.refund(refunded);
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.ask(refunded);

        vm.expectRevert(PinkyVault.UnknownPromise.selector);
        vault.ask(3);
    }

    function test_AskUsesTheArbitrumBlockForTheSettleDelay() public {
        bytes memory sel = abi.encodeWithSignature("arbBlockNumber()");
        vm.mockCall(address(100), sel, abi.encode(uint256(84_000_000)));
        uint256 id = _make();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.mockCall(address(100), sel, abi.encode(uint256(84_010_000)));
        vault.close(id);
        (,,,, uint64 startBlock, uint64 endBlock,,,,,,,,,,) = vault.promises(id);
        assertEq(startBlock, 84_000_000);
        assertEq(endBlock, 84_010_000);

        // The parent chain's block number is far ahead; only the chain's own count matters.
        vm.roll(vm.getBlockNumber() + 1_000_000);
        vm.mockCall(address(100), sel, abi.encode(uint256(84_010_031)));
        vm.expectRevert(PinkyVault.TooEarly.selector);
        vault.ask(id);
        vm.mockCall(address(100), sel, abi.encode(uint256(84_010_032)));
        vm.prank(watcher);
        bytes32 requestId = vault.ask(id);
        string memory body = string(intake.bodyOf(requestId));
        assertEq(vm.parseJsonUint(body, ".window.fromBlock"), 84_000_000);
        assertEq(vm.parseJsonUint(body, ".window.toBlock"), 84_010_000);
        vm.clearMockedCalls();
    }

    function test_AskLeavesNothingBehindWhenTheIntakeReverts() public {
        uint256 id = _make();
        _close(id);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());
        RevertingIntake closed = new RevertingIntake(PRICE);
        vm.prank(owner);
        vault.setProtocol(address(closed), ACTION);
        vm.expectRevert("intake closed");
        vault.ask(id);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Closed));
        assertEq(_bond(id), BOND);
        assertEq(_attempts(id), 0);
        assertEq(imd.balanceOf(address(vault)), BOND);
        assertEq(imd.allowance(address(vault), address(closed)), 0);
    }

    function test_AskRefusesAnIntakeThatPullsTheWrongAmount() public {
        uint256 id = _make();
        _close(id);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());

        ShortPullIntake short_ = new ShortPullIntake(PRICE);
        vm.prank(owner);
        vault.setProtocol(address(short_), ACTION);
        vm.expectRevert(PinkyVault.InvalidPayment.selector);
        vault.ask(id);

        NoPullIntake free = new NoPullIntake(PRICE);
        vm.prank(owner);
        vault.setProtocol(address(free), ACTION);
        vm.expectRevert(PinkyVault.InvalidPayment.selector);
        vault.ask(id);

        assertEq(_bond(id), BOND);
        assertEq(imd.balanceOf(address(vault)), BOND);
        assertEq(imd.allowance(address(vault), address(short_)), 0);
        assertEq(imd.allowance(address(vault), address(free)), 0);
    }

    function test_AskRefusesARequestIdTheIntakeAlreadyGaveOut() public {
        uint256 first = _make();
        uint256 second = _make();
        _close(first);
        _close(second);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());
        FixedIdIntake fixed_ = new FixedIdIntake(PRICE);
        vm.prank(owner);
        vault.setProtocol(address(fixed_), ACTION);
        vault.ask(first);
        assertEq(vault.promiseIdFor(address(fixed_), fixed_.ID()), first);
        vm.expectRevert(PinkyVault.DuplicateRequest.selector);
        vault.ask(second);
        assertEq(uint8(_status(second)), uint8(PinkyVault.Status.Closed));
        assertEq(_bond(second), BOND);
    }

    /// @dev The price room a promise has depends on which protocol `ask` runs under right now,
    /// not on which one it was last asked under: away from the one it was made under it is capped,
    /// back at it the bond pays whatever is quoted.
    function test_ASwitchAwayAndBackLeavesThePromiseAtItsOwnProtocol() public {
        uint256 id = _make();
        _close(id);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());

        StipendIntake other = new StipendIntake(payee, PRICE + 1);
        vm.prank(owner);
        vault.setProtocol(address(other), ACTION);
        vm.expectRevert(PinkyVault.InvalidPayment.selector);
        vault.ask(id);
        other.setPrice(PRICE);
        vm.prank(watcher);
        bytes32 first = vault.ask(id);
        assertEq(vault.promiseIdFor(address(other), first), id);
        (,,, address madeUnder, bytes32 madeFor) = vault.terms(id);
        assertEq(madeUnder, address(intake), "an ask elsewhere does not move the promise's protocol");
        assertEq(madeFor, ACTION);

        // Back at the Intake it was made under, which now charges four times more: the bond pays.
        vm.prank(owner);
        vault.setProtocol(address(intake), ACTION);
        intake.setPrice(2 ether);
        vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        vm.prank(watcher);
        bytes32 second = vault.ask(id);
        assertEq(_bond(id), BOND - PRICE - 2 ether);
        assertEq(vault.promiseIdFor(address(intake), second), id);
        assertEq(imd.balanceOf(payee), PRICE + 2 ether);

        // Away again, the cap is the price it was made under, not the one it just paid.
        vm.prank(owner);
        vault.setProtocol(address(other), ACTION);
        other.setPrice(PRICE + 1);
        vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        vm.expectRevert(PinkyVault.InvalidPayment.selector);
        vault.ask(id);

        _answer(id, second, 0);
        vault.payout(id);
        assertEq(imd.balanceOf(maker), 100 ether - PRICE - 2 ether);
    }

    /// @dev The trade-off the review chose: the Intake a promise was made under is trusted with its
    /// price, so a rise up to what is left of the bond is paid, and a kept maker can get nothing
    /// back. Pinned so that a change to the rule is noticed; it is not approval of a price rise.
    function test_APriceRiseToTheWholeBondLeavesAKeptMakerNothing() public {
        uint256 id = _make();
        _close(id);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());
        intake.setPrice(BOND);
        vm.prank(watcher);
        bytes32 requestId = vault.ask(id);
        assertEq(_bond(id), 0);
        assertEq(imd.balanceOf(payee), BOND);

        _answer(id, requestId, 0);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Kept));
        vm.expectEmit(true, false, false, true, address(vault));
        emit PinkyVault.Paid(id, 0, 0, 0, 0);
        vault.payout(id);
        assertEq(imd.balanceOf(maker), 100 ether - BOND);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_ASecondAskAfterAPriceRiseIsHeldToWhatIsLeft() public {
        uint256 id = _make();
        _close(id);
        _ask(id);
        uint256 left = BOND - PRICE;
        vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        intake.setPrice(left + 1);
        vm.expectRevert(PinkyVault.InvalidPayment.selector);
        vault.ask(id);
        intake.setPrice(left);
        vm.prank(watcher);
        vault.ask(id);
        assertEq(_bond(id), 0);
        assertEq(_attempts(id), 2);
        // The third attempt is open but there is nothing to pay it with.
        vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        intake.setPrice(1);
        vm.expectRevert(PinkyVault.InvalidPayment.selector);
        vault.ask(id);
        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE());
        vm.expectEmit(true, false, false, true, address(vault));
        emit PinkyVault.Refunded(id, 0);
        vault.refund(id);
        assertEq(imd.balanceOf(maker), 100 ether - BOND);
    }

    function test_AskEmitsAsked() public {
        uint256 id = _make();
        _close(id);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());
        bytes32 expected = keccak256(abi.encode(address(intake), uint256(1)));
        vm.expectEmit(true, true, true, true, address(vault));
        emit PinkyVault.Asked(id, watcher, expected, PRICE);
        vm.prank(watcher);
        vault.ask(id);
    }

    function test_AskWritesTheCurrentPanelAndValidityIntoTheBody() public {
        uint256 id = _make();
        vm.prank(owner);
        vault.setPanel(100, 100, 60);
        _close(id);
        bytes32 requestId = _ask(id);
        string memory body = string(intake.bodyOf(requestId));
        assertEq(vm.parseJsonUint(body, ".panelSize"), 100);
        assertEq(vm.parseJsonUint(body, ".quorum"), 100);
        assertEq(vm.parseJsonUint(body, ".validForSeconds"), 60);
        assertLe(bytes(body).length, 16 * 1024);
        (, uint16 askedPanel, uint16 askedQuorum,,) = vault.terms(id);
        assertEq(askedPanel, 100);
        assertEq(askedQuorum, 100);
    }

    function test_BodyOfRefusesUnknownIds() public {
        vm.expectRevert(PinkyVault.UnknownPromise.selector);
        vault.bodyOf(0);
        vm.expectRevert(PinkyVault.UnknownPromise.selector);
        vault.bodyOf(1);
    }

    function test_BodyQuotesTheMakerAndTokenInLowercaseHex() public {
        uint256 id = _make();
        string memory body = vault.bodyOf(id);
        string memory question = vm.parseJsonString(body, ".question");
        assertTrue(vm.contains(question, vm.toLowercase(vm.toString(address(token)))));
        assertTrue(vm.contains(question, vm.toLowercase(vm.toString(maker))));
    }

    // ───────────────────────── the callback ─────────────────────────

    function test_RefusesAnExpiredAttestation() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        intake.complete(requestId, a, sig);

        // Expiring in this very second is still valid.
        a.expiresAt = uint64(vm.getBlockTimestamp());
        sig = _sign(a, SIGNER_PK);
        intake.complete(requestId, a, sig);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Kept));
    }

    function test_RefusesAnAttestationIssuedTooFarAhead() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        a.issuedAt = uint64(vm.getBlockTimestamp() + 5 minutes + 1);
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        intake.complete(requestId, a, sig);

        a.issuedAt = uint64(vm.getBlockTimestamp() + 5 minutes);
        sig = _sign(a, SIGNER_PK);
        intake.complete(requestId, a, sig);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Kept));
    }

    function test_RefusesAnAnswerOfTheWrongLength() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);

        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        a.answer = "";
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(PinkyVault.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);

        a = _attestation(id, 0, bytes16("x"));
        a.answer = abi.encode(uint256(0), uint256(0));
        sig = _sign(a, SIGNER_PK);
        vm.expectRevert(PinkyVault.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);

        a = _attestation(id, 0, bytes16("x"));
        a.answer = hex"01";
        sig = _sign(a, SIGNER_PK);
        vm.expectRevert(PinkyVault.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Asked));
    }

    function test_RefusesAnInconsistentPanel() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);

        // A quorum above the panel size.
        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        a.panelSize = PANEL;
        a.quorum = PANEL + 1;
        a.agreed = PANEL + 1;
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(PinkyVault.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);

        // A quorum below the one the request was bought with.
        a = _attestation(id, 0, bytes16("x"));
        a.quorum = QUORUM - 1;
        sig = _sign(a, SIGNER_PK);
        vm.expectRevert(PinkyVault.InvalidAttestation.selector);
        intake.complete(requestId, a, sig);

        // A bigger panel than asked for is fine.
        a = _attestation(id, 0, bytes16("x"));
        a.panelSize = PANEL + 10;
        a.quorum = QUORUM + 10;
        a.agreed = QUORUM + 10;
        sig = _sign(a, SIGNER_PK);
        intake.complete(requestId, a, sig);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Kept));
    }

    function test_RefusesTheSameOracleRequestIdForTwoPromises() public {
        uint256 first = _make();
        uint256 second = _make();
        _close(first);
        _close(second);
        bytes32 r1 = _ask(first);
        bytes32 r2 = _ask(second);

        OracleAttestation.Attestation memory a = _attestation(first, 0, bytes16("same uuid"));
        intake.complete(r1, a, _sign(a, SIGNER_PK));
        assertTrue(vault.consumed(bytes32(bytes16("same uuid"))));

        a = _attestation(second, 0, bytes16("same uuid"));
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(
            abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, bytes32(bytes16("same uuid")))
        );
        intake.complete(r2, a, sig);
        assertEq(uint8(_status(second)), uint8(PinkyVault.Status.Asked));
    }

    function test_RefusesASignatureMadeForAnotherVault() public {
        PinkyVault neighbour = _deploy(
            owner, address(imd), address(staking), address(intake), ACTION, signer, MIN_BOND, PANEL, QUORUM, VALID_FOR
        );
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, neighbour.attestationDigest(a));
        bytes memory sig = abi.encodePacked(r, s, v);
        assertTrue(neighbour.attestationDigest(a) != vault.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, sig);
    }

    function test_RefusesASignatureForAnotherChain() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        // The literal, not a saved `block.chainid`: via-IR may re-read the opcode after the cheatcode.
        assertEq(block.chainid, 31_337);
        vm.chainId(4663);
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.chainId(31_337);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, sig);
    }

    function test_RefusesATamperedOrMalformedSignature() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        bytes memory sig = _sign(a, SIGNER_PK);

        bytes memory flipped = sig;
        flipped[10] = bytes1(uint8(flipped[10]) ^ 0xFF);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, flipped);

        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, "");

        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, hex"deadbeef");

        // The signed answer, changed after signing.
        a.answer = abi.encode(MAX_OUT + 1);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, sig);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Asked));
    }

    function test_RefusesACallbackFromAnIntakeThatWasNotAsked() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        bytes memory sig = _sign(a, SIGNER_PK);

        StipendIntake other = new StipendIntake(payee, PRICE);
        vm.prank(address(other));
        vm.expectRevert(PinkyVault.UnknownRequest.selector);
        vault.onOracleResult(requestId, a, sig);

        vm.prank(owner);
        vm.expectRevert(PinkyVault.UnknownRequest.selector);
        vault.onOracleResult(requestId, a, sig);

        vm.prank(address(intake));
        vm.expectRevert(PinkyVault.UnknownRequest.selector);
        vault.onOracleResult(keccak256("not a request"), a, sig);
    }

    function test_AnAnswerToARefundedRequestIsRefused() public {
        uint256 id = _make();
        _close(id);
        bytes32 first = _ask(id);
        vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        bytes32 second = _ask(id);
        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE());
        vault.refund(id);
        assertEq(vault.promiseIdFor(address(intake), second), 0, "the latest request is forgotten");
        assertEq(vault.promiseIdFor(address(intake), first), id, "the earlier one is only guarded by status");

        OracleAttestation.Attestation memory a = _attestation(id, MAX_OUT + 1, bytes16("late"));
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(PinkyVault.UnknownRequest.selector);
        intake.complete(second, a, sig);
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        intake.complete(first, a, sig);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Refunded));
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_AZeroAnswerIsStoredNotRefused() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        vm.expectEmit(true, true, false, true, address(vault));
        emit PinkyVault.Verdict(id, bytes32(bytes16(keccak256(abi.encode(requestId)))), true, 0);
        _answer(id, requestId, 0);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Kept));
        assertEq(_observedOut(id), 0);
    }

    function test_APromiseOfZeroIsBrokenByOneWei() public {
        vm.prank(maker);
        uint256 id = vault.make(address(token), 0, 1 hours, BOND);
        _close(id);
        bytes32 requestId = _ask(id);
        _answer(id, requestId, 1);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Broken));
        assertEq(_observedOut(id), 1);
    }

    function test_TheCallbackSucceedsUnderTheRealStipendFromCold() public {
        uint256 kept = _make();
        uint256 broken = _make();
        _close(kept);
        _close(broken);
        bytes32 rk = _ask(kept);
        bytes32 rb = _ask(broken);
        OracleAttestation.Attestation memory ak = _attestation(kept, MAX_OUT, bytes16("k"));
        OracleAttestation.Attestation memory ab = _attestation(broken, type(uint256).max, bytes16("b"));
        bytes memory sk = _sign(ak, SIGNER_PK);
        bytes memory sb = _sign(ab, SIGNER_PK);

        vm.cool(address(vault));
        vm.cool(address(intake));
        assertTrue(intake.completeWithStipend(rk, ak, sk), "kept: ran out of the 200,000 gas stipend");
        vm.cool(address(vault));
        vm.cool(address(intake));
        assertTrue(intake.completeWithStipend(rb, ab, sb), "broken: ran out of the 200,000 gas stipend");
        assertEq(uint8(_status(kept)), uint8(PinkyVault.Status.Kept));
        assertEq(uint8(_status(broken)), uint8(PinkyVault.Status.Broken));
    }

    function test_ARefusedCallbackUnderTheStipendLeavesTheRequestPending() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        bytes memory bad = _sign(a, 0xBAD);
        assertFalse(intake.completeWithStipend(requestId, a, bad));
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Asked));
        assertEq(vault.promiseIdFor(address(intake), requestId), id);
        assertFalse(vault.consumed(a.requestId));
        // The right answer can still land afterwards.
        assertTrue(intake.completeWithStipend(requestId, a, _sign(a, SIGNER_PK)));
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Kept));
    }

    // ───────────────────────── payout ─────────────────────────

    function test_PayoutWhenTheStakerShareIsBelowTheStreamFloorBurnsIt() public {
        // A vault whose minimum bond is exactly three fees, so a bond can be nearly spent.
        PinkyVault tight = _deploy(
            owner, address(imd), address(staking), address(intake), ACTION, signer, 3 * PRICE, PANEL, QUORUM, VALID_FOR
        );
        _stake(staker, 1 ether);
        vm.startPrank(maker);
        imd.approve(address(tight), type(uint256).max);
        uint256 id = tight.make(address(token), 0, 1 hours, 3 * PRICE + 0.02 ether);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 100);
        tight.close(id);
        bytes32 requestId;
        for (uint256 i; i < 3; ++i) {
            vm.roll(vm.getBlockNumber() + tight.SETTLE_DELAY_BLOCKS());
            vm.prank(watcher);
            requestId = tight.ask(id);
            vm.warp(vm.getBlockTimestamp() + tight.ANSWER_TIMEOUT());
        }
        (,,, uint256 left,,,,,,,,,,,,) = tight.promises(id);
        assertEq(left, 0.02 ether);

        (,,,, uint64 startBlock, uint64 endBlock,,,,,,,,,,) = tight.promises(id);
        OracleAttestation.Attestation memory a = _attestation(1, 1, bytes16("tight"));
        a.fromBlock = startBlock;
        a.toBlock = endBlock;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, tight.attestationDigest(a));
        intake.complete(requestId, a, abi.encodePacked(r, s, v));

        uint256 burnBefore = imd.balanceOf(tight.BURN());
        vm.expectEmit(true, false, false, true, address(tight));
        emit PinkyVault.Paid(id, 0, 0.002 ether, 0, 0.018 ether);
        tight.payout(id);
        assertEq(imd.balanceOf(watcher), 0.002 ether);
        assertEq(imd.balanceOf(address(staking)), 0, "below MIN_REWARD the stakers' share burns");
        assertEq(imd.balanceOf(tight.BURN()) - burnBefore, 0.018 ether);
        assertEq(imd.balanceOf(address(tight)), 0);
        assertEq(imd.allowance(address(tight), address(staking)), 0);
        assertEq(staking.rewardRate(), 0);
    }

    function test_PayoutOfAFullySpentBondMovesNothing() public {
        PinkyVault tight = _deploy(
            owner, address(imd), address(staking), address(intake), ACTION, signer, 3 * PRICE, PANEL, QUORUM, VALID_FOR
        );
        _stake(staker, 1 ether);
        vm.startPrank(maker);
        imd.approve(address(tight), type(uint256).max);
        uint256 broken = tight.make(address(token), 0, 1 hours, 3 * PRICE);
        uint256 kept = tight.make(address(token), 0, 1 hours, 3 * PRICE);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 100);
        tight.close(broken);
        tight.close(kept);
        bytes32 rb;
        bytes32 rk;
        for (uint256 i; i < 3; ++i) {
            vm.roll(vm.getBlockNumber() + tight.SETTLE_DELAY_BLOCKS());
            vm.prank(watcher);
            rb = tight.ask(broken);
            vm.prank(watcher);
            rk = tight.ask(kept);
            vm.warp(vm.getBlockTimestamp() + tight.ANSWER_TIMEOUT());
        }
        assertEq(imd.balanceOf(address(tight)), 0);

        (,,,, uint64 startBlock, uint64 endBlock,,,,,,,,,,) = tight.promises(broken);
        OracleAttestation.Attestation memory a = _attestation(1, 1, bytes16("b0"));
        a.fromBlock = startBlock;
        a.toBlock = endBlock;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, tight.attestationDigest(a));
        intake.complete(rb, a, abi.encodePacked(r, s, v));
        a = _attestation(1, 0, bytes16("k0"));
        a.fromBlock = startBlock;
        a.toBlock = endBlock;
        (v, r, s) = vm.sign(SIGNER_PK, tight.attestationDigest(a));
        intake.complete(rk, a, abi.encodePacked(r, s, v));

        uint256 makerBefore = imd.balanceOf(maker);
        uint256 burnBefore = imd.balanceOf(tight.BURN());
        tight.payout(broken);
        tight.payout(kept);
        assertEq(imd.balanceOf(maker), makerBefore);
        assertEq(imd.balanceOf(tight.BURN()), burnBefore);
        assertEq(imd.balanceOf(watcher), 0);
        assertEq(imd.balanceOf(address(staking)), 0);
        (,,, uint256 bondB,,,,,,,, bool paidB,,,,) = tight.promises(broken);
        (,,, uint256 bondK,,,,,,,, bool paidK,,,,) = tight.promises(kept);
        assertEq(bondB + bondK, 0);
        assertTrue(paidB && paidK);
        vm.expectRevert(PinkyVault.AlreadyPaid.selector);
        tight.payout(broken);
    }

    function test_AMakerAskerWithStakersSplitsTheWholeRemainderBetweenStakersAndBurn() public {
        _stake(staker, 1 ether);
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _askAs(id, maker);
        _answer(id, requestId, MAX_OUT + 1);
        uint256 left = BOND - PRICE;
        vm.expectEmit(true, false, false, true, address(vault));
        emit PinkyVault.Paid(id, 0, 0, left / 2, left - left / 2);
        vault.payout(id);
        assertEq(imd.balanceOf(address(staking)), left / 2);
        assertEq(imd.balanceOf(vault.BURN()), left - left / 2);
        assertEq(imd.balanceOf(maker), 100 ether - BOND);
    }

    function test_KeptAfterThreeAsksReturnsWhatIsLeft() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId;
        for (uint256 i; i < 3; ++i) {
            requestId = _ask(id);
            vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        }
        _answer(id, requestId, 0);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PinkyVault.Paid(id, BOND - 3 * PRICE, 0, 0, 0);
        vault.payout(id);
        assertEq(imd.balanceOf(maker), 100 ether - 3 * PRICE);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_PayoutRefusesTheOtherStates() public {
        uint256 id = _make();
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.payout(id);
        _close(id);
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.payout(id);
        _ask(id);
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.payout(id);
        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE());
        vault.refund(id);
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.payout(id);
        vm.expectRevert(PinkyVault.UnknownPromise.selector);
        vault.payout(0);
    }

    // ───────────────────────── refund ─────────────────────────

    function test_RefundAfterOneUnansweredAskWaitsForTheGrace() public {
        uint256 id = _make();
        _close(id);
        (,,,,,,, uint64 closedAt,,,,,,,,) = vault.promises(id);
        _ask(id);
        vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        vm.expectRevert(PinkyVault.TooEarly.selector);
        vault.refund(id);
        vm.warp(uint256(closedAt) + vault.REFUND_GRACE() - 1);
        vm.expectRevert(PinkyVault.TooEarly.selector);
        vault.refund(id);
        vm.warp(uint256(closedAt) + vault.REFUND_GRACE());
        vm.expectEmit(true, false, false, true, address(vault));
        emit PinkyVault.Refunded(id, BOND - PRICE);
        vault.refund(id);
        assertEq(imd.balanceOf(maker), 100 ether - PRICE);
        assertEq(_bond(id), 0);
    }

    function test_RefundRefusesSettledPromises() public {
        uint256 id = _make();
        _close(id);
        _answer(id, _ask(id), 0);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.refund(id);
        vault.payout(id);
        vm.expectRevert(PinkyVault.WrongStatus.selector);
        vault.refund(id);
        vm.expectRevert(PinkyVault.UnknownPromise.selector);
        vault.refund(0);
    }

    function test_RefundDoesNotNeedTheIntake() public {
        uint256 id = _make();
        _close(id);
        _ask(id);
        BrokenQuoteIntake broken = new BrokenQuoteIntake();
        vm.prank(owner);
        vault.setProtocol(address(broken), ACTION);
        vm.expectRevert("no quote");
        vault.make(address(token), MAX_OUT, 1 hours, BOND);
        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE());
        vault.refund(id);
        assertEq(imd.balanceOf(maker), 100 ether - PRICE);
    }

    function test_AnyoneMayRefundButOnlyTheMakerIsPaid() public {
        uint256 id = _make();
        _close(id);
        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE());
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vault.refund(id);
        assertEq(imd.balanceOf(stranger), 0);
        assertEq(imd.balanceOf(maker), 100 ether);
    }

    // ───────────────────────── owner ─────────────────────────

    function test_OwnerSettersRefuseBadValues() public {
        vm.startPrank(owner);
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        vault.setSigner(address(0));
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        vault.setProtocol(address(intake), bytes32(0));
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        vault.setPanel(1, 1, 3_600);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        vault.setPanel(101, 5, 3_600);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        vault.setPanel(7, 1, 3_600);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        vault.setPanel(7, 5, 59);
        vm.expectRevert(PinkyVault.InvalidConfiguration.selector);
        vault.setPanel(7, 5, 30 days + 1);

        vm.expectEmit(true, false, false, true, address(vault));
        emit PinkyVault.PanelSet(2, 2, 60);
        vault.setPanel(2, 2, 60);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PinkyVault.ProtocolSet(address(0x1234), bytes32("oracle.request@oracle-2"));
        vault.setProtocol(address(0x1234), bytes32("oracle.request@oracle-2"));
        assertEq(vault.action(), bytes32("oracle.request@oracle-2"));
        vm.expectEmit(true, false, false, true, address(vault));
        emit OracleAttestationConsumer.OracleSignerSet(address(0x5678));
        vault.setSigner(address(0x5678));
        vm.stopPrank();
    }

    function test_TheOwnerCannotMoveABond() public {
        uint256 id = _make();
        _close(id);
        _answer(id, _ask(id), 0);
        // Nothing on the vault lets the owner withdraw, and the only transfer paths pay the maker,
        // the asker, the stakers or the burn.
        (bool ok,) = address(vault).call(abi.encodeWithSignature("withdraw(address,address,uint256)", imd, owner, 1));
        assertFalse(ok);
        (ok,) = address(vault).call(abi.encodeWithSignature("sweep(address)", imd));
        assertFalse(ok);
        assertEq(imd.balanceOf(address(vault)), BOND - PRICE);
    }

    function test_ANewSignerAppliesToPendingRequests() public {
        uint256 id = _make();
        _close(id);
        bytes32 requestId = _ask(id);
        vm.prank(owner);
        vault.setSigner(vm.addr(0xB0B));
        OracleAttestation.Attestation memory a = _attestation(id, 0, bytes16("x"));
        bytes memory old = _sign(a, SIGNER_PK);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, old);
        intake.complete(requestId, a, _sign(a, 0xB0B));
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Kept));
    }

    // ───────────────────────── fuzz ─────────────────────────

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_KeptExactlyWhenTheSumIsWithinThePromise(uint256 maxOut, uint256 out) public {
        vm.prank(maker);
        uint256 id = vault.make(address(token), maxOut, 1 hours, BOND);
        _close(id);
        _answer(id, _ask(id), out);
        bool kept = out <= maxOut;
        assertEq(uint8(_status(id)), uint8(kept ? PinkyVault.Status.Kept : PinkyVault.Status.Broken));
        assertEq(_observedOut(id), out);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_BrokenSplitIsExact(uint256 bond, uint8 asks, bool makerAsks, bool staked) public {
        bond = bound(bond, MIN_BOND, 100 ether);
        asks = uint8(bound(asks, 1, 3));
        if (staked) _stake(staker, 1 ether);
        vm.prank(maker);
        uint256 id = vault.make(address(token), 0, 1 hours, bond);
        _close(id);
        bytes32 requestId;
        for (uint256 i; i < asks; ++i) {
            requestId = _askAs(id, makerAsks ? maker : watcher);
            vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        }
        _answer(id, requestId, 1);
        vault.payout(id);

        uint256 left = bond - asks * PRICE;
        uint256 bounty = makerAsks ? 0 : left / 10;
        uint256 rest = left - bounty;
        uint256 toStakers = staked && rest / 2 >= staking.MIN_REWARD() ? rest / 2 : 0;
        assertEq(imd.balanceOf(watcher), bounty, "bounty");
        assertEq(imd.balanceOf(address(staking)), toStakers, "stakers");
        assertEq(imd.balanceOf(vault.BURN()), rest - toStakers, "burn");
        assertEq(imd.balanceOf(maker), 100 ether - bond, "maker");
        assertEq(imd.balanceOf(address(vault)), 0, "vault");
        assertEq(imd.balanceOf(payee), asks * PRICE, "intake");
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_RefundReturnsExactlyTheUnspentBond(uint256 bond, uint8 asks) public {
        bond = bound(bond, MIN_BOND, 100 ether);
        asks = uint8(bound(asks, 0, 3));
        vm.prank(maker);
        uint256 id = vault.make(address(token), 0, 1 hours, bond);
        _close(id);
        for (uint256 i; i < asks; ++i) {
            _ask(id);
            vm.warp(vm.getBlockTimestamp() + vault.ANSWER_TIMEOUT());
        }
        vm.warp(vm.getBlockTimestamp() + vault.REFUND_GRACE());
        vault.refund(id);
        assertEq(imd.balanceOf(maker), 100 ether - asks * PRICE);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Refunded));
    }
}
