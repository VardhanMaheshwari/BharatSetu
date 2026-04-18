// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MintBridge} from "../src/MintBridge.sol";

contract MintBridgeTest is Test {
    MintBridge public bridge;
    address public relayer = address(0xBE1A4E);
    address public user    = address(0xA11CE);
    bytes32 public nonceHash = keccak256(abi.encodePacked(user, bytes32("transfer-1")));

    function setUp() public {
        bridge = new MintBridge(relayer);
    }

    function test_mint_on_proof() public {
        vm.prank(relayer);
        bridge.mintOnProof(user, nonceHash, 100 ether);

        assertEq(bridge.balanceOf(user), 100 ether);
        assertTrue(bridge.usedNonces(nonceHash));
    }

    function test_cannot_double_mint() public {
        vm.prank(relayer);
        bridge.mintOnProof(user, nonceHash, 100 ether);

        vm.expectRevert(abi.encodeWithSelector(MintBridge.NonceAlreadyUsed.selector, nonceHash));
        vm.prank(relayer);
        bridge.mintOnProof(user, nonceHash, 100 ether);
    }

    function test_only_relayer_can_mint() public {
        vm.expectRevert(abi.encodeWithSelector(MintBridge.NotRelayer.selector, address(this)));
        bridge.mintOnProof(user, nonceHash, 100 ether);
    }

    function test_revert_zero_amount() public {
        vm.expectRevert(MintBridge.ZeroAmount.selector);
        vm.prank(relayer);
        bridge.mintOnProof(user, nonceHash, 0);
    }

    function test_revert_zero_address() public {
        vm.expectRevert(MintBridge.ZeroAddress.selector);
        vm.prank(relayer);
        bridge.mintOnProof(address(0), nonceHash, 100 ether);
    }

    function test_set_relayer() public {
        address newRelayer = address(0xBEEF);
        bridge.setRelayer(newRelayer);
        assertEq(bridge.relayer(), newRelayer);
    }

    function test_total_supply_tracks_mints() public {
        vm.startPrank(relayer);
        bridge.mintOnProof(user, nonceHash, 100 ether);
        bridge.mintOnProof(user, keccak256("other-nonce"), 50 ether);
        vm.stopPrank();

        assertEq(bridge.totalSupply(), 150 ether);
    }
}
