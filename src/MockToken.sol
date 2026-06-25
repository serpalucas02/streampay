// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockToken
 * @author Lucas Serpa
 * @notice Minimal mintable ERC-20 for local tests and the testnet demo.
 * @dev Mint is intentionally open (faucet-style) so anyone can grab test tokens
 *      to try the app. Not for production.
 */
contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @notice Mint test tokens to any address.
    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}
