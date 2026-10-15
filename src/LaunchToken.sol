// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain, immutable launch supply. The launch factory performs the allocation.
contract LaunchToken is ERC20 {
    constructor() ERC20("Pinky", "PINKY") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
