// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Sepolia-only learning token; the deployer receives the supply.
contract StudyToken is ERC20 {
    constructor() ERC20("Study Token", "STUDY") {
        _mint(msg.sender, 1_000_000 ether);
    }
}
