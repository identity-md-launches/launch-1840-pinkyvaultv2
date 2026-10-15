// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {PinkyVault} from "../../src/PinkyVault.sol";
import {PinkyStaking} from "../../src/PinkyStaking.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {StipendIntake} from "../mocks/MoreMocks.sol";

/// @dev The launch's configuration (panel 7, quorum 5, 86,400 seconds, 5 IMD minimum bond, 0.5 IMD
/// price) around a mock Intake that can deliver under the real stipend.
abstract contract PinkyFixture is Test {
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");
    uint256 constant PRICE = 0.5 ether;
    uint256 constant MIN_BOND = 5 ether;
    uint256 constant BOND = 10 ether;
    uint256 constant MAX_OUT = 1_000 ether;
    uint16 constant PANEL = 7;
    uint16 constant QUORUM = 5;
    uint32 constant VALID_FOR = 86_400;
    uint256 constant SIGNER_PK = 0xA11CE;
    uint256 constant START_BLOCK = 1_000;

    MockERC20 imd;
    MockERC20 pinky;
    MockERC20 token;
    StipendIntake intake;
    PinkyStaking staking;
    PinkyVault vault;

    address owner = makeAddr("owner");
    address payee = makeAddr("payee");
    address maker = makeAddr("maker");
    address watcher = makeAddr("watcher");
    address staker = makeAddr("staker");
    address signer;

    function setUp() public virtual {
        vm.warp(1_790_000_000);
        vm.roll(START_BLOCK);
        signer = vm.addr(SIGNER_PK);
        imd = new MockERC20("Identity.md", "IMD");
        pinky = new MockERC20("Pinky", "PINKY");
        token = new MockERC20("Meme", "MEME");
        intake = new StipendIntake(payee, PRICE);
        staking = new PinkyStaking(address(pinky), address(imd));
        vault = new PinkyVault(
            owner, address(imd), address(staking), address(intake), ACTION, signer, MIN_BOND, PANEL, QUORUM, VALID_FOR
        );
        imd.mint(maker, 100 ether);
        vm.prank(maker);
        imd.approve(address(vault), type(uint256).max);
    }

    // ───────────────────────── driving the vault ─────────────────────────

    function _make() internal returns (uint256 id) {
        vm.prank(maker);
        id = vault.make(address(token), MAX_OUT, 1 hours, BOND);
    }

    function _close(uint256 id) internal {
        (,,,,,, uint64 endTime,,,,,,,,,) = vault.promises(id);
        if (vm.getBlockTimestamp() < endTime) vm.warp(endTime);
        vm.roll(vm.getBlockNumber() + 36_000);
        vault.close(id);
    }

    function _ask(uint256 id) internal returns (bytes32 requestId) {
        return _askAs(id, watcher);
    }

    function _askAs(uint256 id, address who) internal returns (bytes32 requestId) {
        (,,,,, uint64 endBlock,,,,,,,,,,) = vault.promises(id);
        uint256 ready = uint256(endBlock) + vault.SETTLE_DELAY_BLOCKS();
        if (vm.getBlockNumber() < ready) vm.roll(ready);
        vm.prank(who);
        requestId = vault.ask(id);
    }

    function _stake(address who, uint256 amount) internal {
        pinky.mint(who, amount);
        vm.startPrank(who);
        pinky.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    // ───────────────────────── attestations ─────────────────────────

    function _attestation(uint256 id, uint256 out, bytes16 oracleId)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        (,,,, uint64 startBlock, uint64 endBlock,,,,,,,,,,) = vault.promises(id);
        a.requestId = bytes32(oracleId);
        a.chainId = block.chainid;
        a.questionHash = keccak256("q");
        a.answerType = OracleAttestation.ANSWER_UINT256;
        a.answer = abi.encode(out);
        a.figure = out;
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

    function _sign(OracleAttestation.Attestation memory a, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, vault.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _answer(uint256 id, bytes32 requestId, uint256 out) internal returns (uint256 gasUsed) {
        OracleAttestation.Attestation memory a = _attestation(id, out, bytes16(keccak256(abi.encode(requestId))));
        gasUsed = intake.complete(requestId, a, _sign(a, SIGNER_PK));
    }

    function _deliver(uint256 id, bytes32 requestId, OracleAttestation.Attestation memory a) internal {
        id;
        intake.complete(requestId, a, _sign(a, SIGNER_PK));
    }

    // ───────────────────────── reading the vault ─────────────────────────

    function _status(uint256 id) internal view returns (PinkyVault.Status status) {
        (,,,,,,,,,, status,,,,,) = vault.promises(id);
    }

    function _bond(uint256 id) internal view returns (uint256 bond) {
        (,,, bond,,,,,,,,,,,,) = vault.promises(id);
    }

    function _asker(uint256 id) internal view returns (address asker) {
        (,,,,,,,,,,,, asker,,,) = vault.promises(id);
    }

    function _attempts(uint256 id) internal view returns (uint8 attempts) {
        (,,,,,,,,, attempts,,,,,,) = vault.promises(id);
    }

    function _paid(uint256 id) internal view returns (bool paid) {
        (,,,,,,,,,,, paid,,,,) = vault.promises(id);
    }

    function _observedOut(uint256 id) internal view returns (uint256 out) {
        (,,,,,,,,,,,,,,, out) = vault.promises(id);
    }
}
