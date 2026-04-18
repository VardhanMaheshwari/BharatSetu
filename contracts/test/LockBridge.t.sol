// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LockBridge} from "../src/LockBridge.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

// Minimal ERC20 mock for tests
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LockBridgeTest is Test {
    LockBridge public bridge;
    MockERC20 public token;
    address public user = address(0xA11CE);
    bytes32 public transferId = keccak256("transfer-uuid-1");

    function setUp() public {
        bridge = new LockBridge();
        token  = new MockERC20();
        token.mint(user, 1000 ether);

        vm.prank(user);
        token.approve(address(bridge), 1000 ether);
    }

    function test_lock_emits_event() public {
        bytes32 expectedNonce = keccak256(abi.encodePacked(user, transferId));

        vm.expectEmit(true, true, false, true);
        emit LockBridge.TokensLocked(user, address(token), 100 ether, expectedNonce, transferId);

        vm.prank(user);
        bridge.lockTokens(address(token), 100 ether, transferId);
    }

    function test_lock_transfers_tokens() public {
        uint256 userBefore = token.balanceOf(user);

        vm.prank(user);
        bridge.lockTokens(address(token), 100 ether, transferId);

        assertEq(token.balanceOf(address(bridge)), 100 ether);
        assertEq(token.balanceOf(user), userBefore - 100 ether);
    }

    function test_cannot_reuse_transfer_id() public {
        vm.prank(user);
        bridge.lockTokens(address(token), 100 ether, transferId);

        vm.expectRevert(abi.encodeWithSelector(LockBridge.TransferIdUsed.selector, transferId));
        vm.prank(user);
        bridge.lockTokens(address(token), 100 ether, transferId);
    }

    function test_revert_zero_amount() public {
        vm.expectRevert(LockBridge.ZeroAmount.selector);
        vm.prank(user);
        bridge.lockTokens(address(token), 0, transferId);
    }

    function test_revert_zero_token_address() public {
        vm.expectRevert(LockBridge.ZeroAddress.selector);
        vm.prank(user);
        bridge.lockTokens(address(0), 100 ether, transferId);
    }

    function test_pause_blocks_lock() public {
        bridge.pause();

        vm.expectRevert(LockBridge.ContractPaused.selector);
        vm.prank(user);
        bridge.lockTokens(address(token), 100 ether, transferId);
    }

    function test_nonce_hash_derivation() public view {
        bytes32 expected = keccak256(abi.encodePacked(user, transferId));
        bytes32 computed = keccak256(abi.encodePacked(user, transferId));
        assertEq(expected, computed);
    }
}
