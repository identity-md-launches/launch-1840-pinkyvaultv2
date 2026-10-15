// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {MockIntake} from "./Mocks.sol";

/// @dev An ERC-20 that keeps a slice of every transfer, to stand in for an IMD that is not plain.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 feeBps_) ERC20("Fee", "FEE") {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value * feeBps / 10_000;
            super._update(from, address(0xFEE), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @dev The mock Intake, plus a delivery that runs the callback exactly the way the real Intake
/// does: inside a try with a 200,000 gas stipend, reporting success rather than bubbling a revert.
contract StipendIntake is MockIntake {
    constructor(address payee_, uint256 price_) MockIntake(payee_, price_) {}

    function completeWithStipend(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (bool ok)
    {
        (address target, bytes4 selector,,) = this.requests(requestId);
        (ok,) = target.call{gas: 200_000}(abi.encodePacked(selector, abi.encode(requestId, a, signature)));
    }
}

/// @dev An Intake whose `request` always reverts, as a paused or withdrawn one would.
contract RevertingIntake is IIntake {
    uint256 public price;

    constructor(uint256 price_) {
        price = price_;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32, bytes calldata, Callback calldata, address, uint256) external payable returns (bytes32) {
        revert("intake closed");
    }
}

/// @dev An Intake whose `priceOf` reverts, so `make` and `ask` cannot even quote.
contract BrokenQuoteIntake is IIntake {
    function priceOf(bytes32, address) external pure returns (uint256) {
        revert("no quote");
    }

    function request(bytes32, bytes calldata, Callback calldata, address, uint256) external payable returns (bytes32) {
        revert("no quote");
    }
}

/// @dev An Intake that pulls less than it was offered. The vault must notice the bond is not
/// where it expects it and refuse, rather than record a price it did not pay.
contract ShortPullIntake is IIntake {
    uint256 public price;
    uint256 public nonce;

    constructor(uint256 price_) {
        price = price_;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32, bytes calldata, Callback calldata, address asset, uint256 amount)
        external
        payable
        returns (bytes32)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount - 1);
        return keccak256(abi.encode(address(this), ++nonce));
    }
}

/// @dev An Intake that pulls nothing at all, as a free or faulty one would.
contract NoPullIntake is IIntake {
    uint256 public price;
    uint256 public nonce;

    constructor(uint256 price_) {
        price = price_;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32, bytes calldata, Callback calldata, address, uint256) external payable returns (bytes32) {
        return keccak256(abi.encode(address(this), ++nonce));
    }
}

/// @dev An Intake that hands out the same request id twice.
contract FixedIdIntake is IIntake {
    uint256 public price;
    bytes32 public constant ID = keccak256("the only id");

    constructor(uint256 price_) {
        price = price_;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32, bytes calldata, Callback calldata, address asset, uint256 amount)
        external
        payable
        returns (bytes32)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        return ID;
    }
}
