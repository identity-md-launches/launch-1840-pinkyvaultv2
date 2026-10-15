// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The IdentityMD Intake, version 2 (0xa43e6f75ee006411f79ac1c84120606c2330de82 on every
/// chain, live since 2026-10-10). Version 1's functions, plus a request that also names a function
/// for a refusal or a result that never came.
interface IIntakeV2 {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function priceOf(bytes32 action, address asset) external view returns (uint256);
    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId);
}
