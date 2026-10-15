// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {PinkyVault} from "../src/PinkyVault.sol";

// Test-only exposure of the unchanged verifier, to accept the bytes32[] protocol vector.
contract ConformanceHarness is PinkyVault {
    constructor(address owner_, address imd_, address staking_, address intake_, address signer_)
        PinkyVault(
            owner_, imd_, staking_, intake_, bytes32("oracle.request@oracle-1"), signer_, 5 ether, 7, 5, 86400
        )
    {}

    function verifyVector(OracleAttestation.Attestation calldata a, bytes calldata signature) external view {
        _verifyAttestation(a, signature);
    }
}

/// @notice The conformance test the `oracle-consumer` skill hands to builders, pointed at
/// PinkyVault: the protocol's vector values, its digest and a signature made by the protocol's own
/// signer code. A consumer whose struct, type string or domain differs passes its self-signed
/// tests and fails this one.
contract OracleConsumerConformanceTest is Test {
    // ---- the protocol's vector: do not change these ----
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    ConformanceHarness consumer;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        deployCodeTo(
            "OracleConsumerConformance.t.sol:ConformanceHarness",
            abi.encode(address(this), address(0x1111), address(0x2222), address(0x3333), SIGNER),
            VECTOR_CONSUMER
        );
        consumer = ConformanceHarness(VECTOR_CONSUMER);
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

    /// @notice The digest the vault verifies is the one the oracle signs.
    function test_DigestMatchesTheProtocol() public view {
        assertEq(
            consumer.attestationDigest(vector()),
            VECTOR_DIGEST,
            "struct, type string or domain differs from the protocol's"
        );
    }

    /// @notice The vault's callback selector is the one the Intake calls.
    function test_CallbackSelectorIsCanonical() public view {
        assertEq(
            consumer.onOracleResult.selector,
            bytes4(keccak256(bytes(CALLBACK))),
            "callback parameters differ from the protocol's"
        );
        assertEq(consumer.onOracleResult.selector, bytes4(0x510379c7));
    }

    /// @notice The unchanged verification path accepts the exact protocol vector signature.
    function test_AcceptsTheProtocolSignature() public view {
        consumer.verifyVector(vector(), VECTOR_SIGNATURE);
    }
}
