// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {PinkyVault} from "../src/PinkyVault.sol";
import {PinkyStaking} from "../src/PinkyStaking.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {StipendIntake} from "./mocks/MoreMocks.sol";

/// @notice The protocol's conformance vector, taken through the vault's real path: the vault at
/// the vector's address on the vector's chain, a promise made, closed and asked through a mock
/// Intake, and the answer signed by the vector's attester key and delivered under the 200,000 gas
/// stipend. The conformance test proves the digest; this proves the callback accepts what that
/// key signs for it, and refuses the vector's own answer only for its shape, not its signature.
contract OracleConsumerVectorKeyTest is Test {
    // ---- the protocol's vector: do not change these ----
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    uint256 constant PRICE = 0.5 ether;
    uint256 constant BOND = 10 ether;

    MockERC20 imd;
    MockERC20 pinky;
    MockERC20 token;
    StipendIntake intake;
    PinkyStaking staking;
    PinkyVault vault;
    address maker = makeAddr("maker");

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT - 2 hours);
        vm.roll(1_000);
        imd = new MockERC20("Identity.md", "IMD");
        pinky = new MockERC20("Pinky", "PINKY");
        token = new MockERC20("Meme", "MEME");
        intake = new StipendIntake(address(0xFEE), PRICE);
        staking = new PinkyStaking(address(pinky), address(imd));
        deployCodeTo(
            "PinkyVault.sol:PinkyVault",
            abi.encode(
                address(this),
                address(imd),
                address(staking),
                address(intake),
                bytes32("oracle.request@oracle-1"),
                SIGNER,
                5 ether,
                uint16(5),
                uint16(4),
                uint32(86_400)
            ),
            VECTOR_CONSUMER
        );
        vault = PinkyVault(VECTOR_CONSUMER);
        imd.mint(maker, BOND);
        vm.prank(maker);
        imd.approve(address(vault), BOND);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function _askOne() internal returns (uint256 id, bytes32 requestId) {
        vm.prank(maker);
        id = vault.make(address(token), 1_000 ether, 1 hours, BOND);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 14_400);
        vault.close(id);
        vm.roll(vm.getBlockNumber() + vault.SETTLE_DELAY_BLOCKS());
        requestId = vault.ask(id);
        vm.warp(ISSUED_AT);
    }

    function _status(uint256 id) internal view returns (PinkyVault.Status status) {
        (,,,,,,,,,, status,,,,,) = vault.promises(id);
    }

    function test_TheVaultAtTheVectorAddressReproducesTheDigest() public view {
        assertEq(vault.attestationDigest(vector()), VECTOR_DIGEST);
        assertEq(vault.oracleSigner(), SIGNER);
    }

    /// @notice The vector's signature verifies in the callback; what the vault refuses is the
    /// vector's block range and answer shape, which come after the signature check.
    function test_TheVectorSignatureGetsPastTheSignatureCheckInTheCallback() public {
        (, bytes32 requestId) = _askOne();
        OracleAttestation.Attestation memory a = vector();
        vm.expectRevert(PinkyVault.InvalidAttestation.selector);
        intake.complete(requestId, a, VECTOR_SIGNATURE);

        // The same values with one bit of the signature changed fail earlier, on the signature.
        bytes memory tampered = VECTOR_SIGNATURE;
        tampered[0] = bytes1(uint8(tampered[0]) ^ 0x01);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.complete(requestId, a, tampered);
    }

    /// @notice An answer for the promise, signed by the vector key, settles it under the stipend.
    function test_AnAnswerSignedByTheVectorKeyIsAcceptedThroughTheCallback() public {
        (uint256 id, bytes32 requestId) = _askOne();
        (,,,, uint64 startBlock, uint64 endBlock,,,,,,,,,,) = vault.promises(id);
        OracleAttestation.Attestation memory a = vector();
        a.requestId = keccak256("a request for the promise");
        a.chainId = VECTOR_CHAIN;
        a.answerType = OracleAttestation.ANSWER_UINT256;
        a.answer = abi.encode(uint256(1_000 ether + 1));
        a.figure = 1_000 ether + 1;
        a.fromBlock = startBlock;
        a.toBlock = endBlock;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, vault.attestationDigest(a));
        vm.cool(address(vault));
        assertTrue(
            intake.completeWithStipend(requestId, a, abi.encodePacked(r, s, v)),
            "the callback did not run to the end under the 200,000 gas stipend"
        );
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Broken));
        assertTrue(vault.consumed(a.requestId));
        assertEq(vault.promiseIdFor(address(intake), requestId), 0);
    }

    /// @notice The same signed answer presented again is refused: the request is settled.
    function test_TheSameAnswerIsNotAcceptedTwice() public {
        (uint256 id, bytes32 requestId) = _askOne();
        (,,,, uint64 startBlock, uint64 endBlock,,,,,,,,,,) = vault.promises(id);
        OracleAttestation.Attestation memory a = vector();
        a.requestId = keccak256("once");
        a.chainId = VECTOR_CHAIN;
        a.answerType = OracleAttestation.ANSWER_UINT256;
        a.answer = abi.encode(uint256(0));
        a.fromBlock = startBlock;
        a.toBlock = endBlock;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, vault.attestationDigest(a));
        bytes memory sig = abi.encodePacked(r, s, v);
        intake.complete(requestId, a, sig);
        assertEq(uint8(_status(id)), uint8(PinkyVault.Status.Kept));
        assertFalse(intake.completeWithStipend(requestId, a, sig));
        vm.expectRevert(PinkyVault.UnknownRequest.selector);
        intake.complete(requestId, a, sig);
    }
}
