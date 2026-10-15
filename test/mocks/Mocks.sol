// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Takes the payment like the real Intake and lets a test play the writer.
contract MockIntake is IIntake {
    struct Request {
        address target;
        bytes4 selector;
        bytes body;
        bytes4 onFailure;
    }

    address public immutable payee;
    uint256 public price;
    uint256 public nonce;
    mapping(bytes32 => Request) public requests;
    bytes32 public lastRequestId;

    constructor(address payee_, uint256 price_) {
        payee = payee_;
        price = price_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        require(amount >= price, "PriceNotMet");
        IERC20(asset).transferFrom(msg.sender, payee, amount);
        requestId = keccak256(abi.encode(address(this), ++nonce));
        requests[requestId] = Request(callback.target, callback.selector, body, bytes4(0));
        lastRequestId = requestId;
    }

    /// @dev Version 2's request: the same, plus a function for a refusal or a failure.
    function requestWithFailure(
        bytes32,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId) {
        require(amount >= price, "PriceNotMet");
        require(onFailure == bytes4(0) || callback.target != address(0), "FailureHookWithoutTarget");
        IERC20(asset).transferFrom(msg.sender, payee, amount);
        requestId = keccak256(abi.encode(address(this), ++nonce));
        requests[requestId] = Request(callback.target, callback.selector, body, onFailure);
        lastRequestId = requestId;
    }

    /// @dev Plays the writer reporting a refusal (status 1) or no result (status 2).
    function fail(bytes32 requestId, uint8 status, bytes32 reason) external returns (uint256 gasUsed) {
        Request storage r = requests[requestId];
        uint256 before = gasleft();
        (bool ok, bytes memory out) = r.target.call(
            abi.encodeWithSelector(r.onFailure, requestId, status, reason, uint16(3), uint16(7), bytes(""))
        );
        gasUsed = before - gasleft();
        if (!ok) {
            assembly {
                revert(add(out, 32), mload(out))
            }
        }
    }

    function bodyOf(bytes32 requestId) external view returns (bytes memory) {
        return requests[requestId].body;
    }

    /// @dev The real Intake calls inside a try with 200,000 gas; the test wants the revert.
    function complete(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (uint256 gasUsed)
    {
        Request storage r = requests[requestId];
        uint256 before = gasleft();
        (bool ok, bytes memory out) = r.target.call(abi.encodePacked(r.selector, abi.encode(requestId, a, signature)));
        gasUsed = before - gasleft();
        if (!ok) {
            assembly {
                revert(add(out, 32), mload(out))
            }
        }
    }
}
