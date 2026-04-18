// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./utils/ERC20.sol";

/// Simple mintable ERC20 for testnet — anyone can mint for testing.
contract TestToken is ERC20("Test Carbon Credit", "tCCS") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
