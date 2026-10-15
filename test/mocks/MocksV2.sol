// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {IIntakeV2} from "../../src/interfaces/IIntakeV2.sol";
import {MockIntake} from "./Mocks.sol";

/// @dev The mock Intake, delivering both callbacks the way the real Intake does: inside a try with
/// the 200,000 gas stipend, reporting success rather than bubbling a revert.
contract StipendIntakeV2 is MockIntake {
    constructor(address payee_, uint256 price_) MockIntake(payee_, price_) {}

    function completeWithStipend(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (bool ok)
    {
        (address target, bytes4 selector,,) = this.requests(requestId);
        (ok,) = target.call{gas: 200_000}(abi.encodePacked(selector, abi.encode(requestId, a, signature)));
    }

    function failWithStipend(bytes32 requestId, uint8 status, bytes32 reason) external returns (bool ok) {
        (address target,,, bytes4 onFailure) = this.requests(requestId);
        (ok,) = target.call{gas: 200_000}(
            abi.encodeWithSelector(onFailure, requestId, status, reason, uint16(0), uint16(0), bytes(""))
        );
    }
}

/// @dev A version 2 Intake whose `requestWithFailure` always reverts, as a paused one would.
contract RevertingIntakeV2 is IIntakeV2 {
    uint256 public price;

    constructor(uint256 price_) {
        price = price_;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function requestWithFailure(bytes32, bytes calldata, Callback calldata, bytes4, address, uint256)
        external
        pure
        returns (bytes32)
    {
        revert("intake closed");
    }
}

/// @dev A version 2 Intake whose `priceOf` reverts, so nothing can be quoted.
contract BrokenQuoteIntakeV2 is IIntakeV2 {
    function priceOf(bytes32, address) external pure returns (uint256) {
        revert("no quote");
    }

    function requestWithFailure(bytes32, bytes calldata, Callback calldata, bytes4, address, uint256)
        external
        pure
        returns (bytes32)
    {
        revert("no quote");
    }
}

/// @dev A version 2 Intake that pulls `short` less than it was offered (or nothing, when `short`
/// equals the price), and hands out a fixed id when asked to.
contract OddPullIntakeV2 is IIntakeV2 {
    uint256 public price;
    uint256 public short;
    bool public fixedId;
    uint256 public nonce;
    bytes32 public constant ID = keccak256("the only id");

    constructor(uint256 price_, uint256 short_, bool fixedId_) {
        price = price_;
        short = short_;
        fixedId = fixedId_;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function requestWithFailure(bytes32, bytes calldata, Callback calldata, bytes4, address asset, uint256 amount)
        external
        returns (bytes32)
    {
        if (amount > short) IERC20(asset).transferFrom(msg.sender, address(this), amount - short);
        return fixedId ? ID : keccak256(abi.encode(address(this), ++nonce));
    }
}

/// @dev A fee sink that reports success but takes less than it is told, or nothing at all.
contract ShortSink {
    IERC20 public immutable imd;
    uint256 public immutable keep;

    constructor(address imd_, uint256 keep_) {
        imd = IERC20(imd_);
        keep = keep_;
    }

    function notify(uint256 amount) external {
        if (amount > keep) imd.transferFrom(msg.sender, address(this), amount - keep);
    }
}

/// @dev A fee sink that always refuses.
contract RefusingSink {
    function notify(uint256) external pure {
        revert("not now");
    }
}

/// @dev A contract with code but no `notify`, as a wrong address with code would be.
contract DeafSink {
    function ping() external pure returns (bool) {
        return true;
    }
}
