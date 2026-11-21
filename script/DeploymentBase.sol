// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Shared configuration checks; signing is provided by forge --account, never by .env private keys.
abstract contract DeploymentBase is Script {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;

    function _address(string memory key) internal view returns (address value) {
        value = vm.envAddress(key);
        require(value != address(0), string.concat(key, " must not be zero"));
    }

    function _destinationChainId() internal view returns (uint256 value) {
        value = vm.envUint("DESTINATION_CHAIN_ID");
        require(value > 0, "DESTINATION_CHAIN_ID must not be zero");
    }

    function _reactiveSigner() internal view returns (address) {
        require(block.chainid == vm.envUint("REACTIVE_CHAIN_ID"), "Wrong Reactive RPC chain ID");
        require(SYSTEM.code.length > 0, "Omni system contract missing");
        return _address("REACTIVE_DEPLOYER");
    }

    function _destinationSigner() internal view returns (address) {
        require(block.chainid == _destinationChainId(), "Wrong destination RPC chain ID");
        require(_address("DESTINATION_CALLBACK_PROXY_ADDR").code.length > 0, "Callback proxy has no code");
        require(_address("ROUTER_ADDR").code.length > 0, "Router has no code");
        return _address("DESTINATION_DEPLOYER");
    }

    function _report(string memory key, address value) internal pure {
        console2.log(key, value);
    }
}
