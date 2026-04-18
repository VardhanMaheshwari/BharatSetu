// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TestToken} from "../src/TestToken.sol";

/// Deploy TestToken on Polygon Amoy + mint 1000 tCCS to deployer:
///   forge script script/DeployTestToken.s.sol --rpc-url amoy --broadcast
contract DeployTestToken is Script {
    function run() external {
        vm.startBroadcast();

        TestToken token = new TestToken();
        // Mint 1000 tCCS (18 decimals) to the deployer for testing
        token.mint(msg.sender, 1000 * 10 ** 18);

        vm.stopBroadcast();

        console.log("TestToken (Amoy):", address(token));
        console.log("Minted 1000 tCCS to:", msg.sender);
    }
}
