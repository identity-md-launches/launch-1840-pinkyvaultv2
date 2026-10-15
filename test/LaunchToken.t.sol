// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    LaunchToken token;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_NameSymbolAndDecimals() public view {
        assertEq(token.name(), "Pinky");
        assertEq(token.symbol(), "PINKY");
        assertEq(token.decimals(), 18);
    }

    function test_MintsTheWholeFixedSupplyToTheDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_TransferMovesExactlyWhatItWasAsked() public {
        address to = makeAddr("to");
        assertTrue(token.transfer(to, 1 ether));
        assertEq(token.balanceOf(to), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_NothingCanMintAfterLaunch() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
