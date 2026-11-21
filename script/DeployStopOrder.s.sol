// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {DeploymentBase} from "./DeploymentBase.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {UniswapDemoStopOrderReactive} from "../src/demos/uniswap-v2-stop-order/UniswapDemoStopOrderReactive.sol";
import {UniswapDemoStopOrderCallback} from "../src/demos/uniswap-v2-stop-order/UniswapDemoStopOrderCallback.sol";

/// @notice Invoke each phase on its own chain using --sig. See README.md.
contract DeployStopOrder is DeploymentBase {
    function deployReactive() external returns (UniswapDemoStopOrderReactive reactive) {
        address signer = _reactiveSigner();
        uint256 chainId = _destinationChainId();
        address pair = _address("PAIR_ADDR");
        address client = _address("CLIENT_WALLET");
        bool sellToken0 = vm.envBool("SELL_TOKEN0");
        uint256 coefficient = vm.envUint("PRICE_COEFFICIENT");
        uint256 threshold = vm.envUint("STOP_LOSS_THRESHOLD");
        uint256 funding = vm.envUint("REACTIVE_FUNDING_WEI");
        vm.startBroadcast(signer);
        reactive =
            new UniswapDemoStopOrderReactive{value: funding}(chainId, pair, client, sellToken0, coefficient, threshold);
        vm.stopBroadcast();
        _report("SINGLE_REACTIVE_ADDR", address(reactive));
    }

    function deployCallback() external returns (UniswapDemoStopOrderCallback callback_) {
        address signer = _destinationSigner();
        address reactive = _address("SINGLE_REACTIVE_ADDR");
        IPayable proxy = IPayable(payable(_address("DESTINATION_CALLBACK_PROXY_ADDR")));
        address router = _address("ROUTER_ADDR");
        uint256 funding = vm.envUint("CALLBACK_FUNDING_WEI");
        vm.startBroadcast(signer);
        callback_ = new UniswapDemoStopOrderCallback{value: funding}(proxy, reactive, router);
        vm.stopBroadcast();
        _report("SINGLE_CALLBACK_ADDR", address(callback_));
    }

    function configure() external {
        address signer = _reactiveSigner();
        address reactiveAddress = _address("SINGLE_REACTIVE_ADDR");
        require(reactiveAddress.code.length > 0, "Reactive contract has no code");
        UniswapDemoStopOrderReactive reactive = UniswapDemoStopOrderReactive(payable(reactiveAddress));
        require(reactive.owner() == signer, "Signer is not Reactive owner");
        require(reactive.destinationChainId() == _destinationChainId(), "Destination chain ID mismatch");
        require(reactive.stop_order() == address(0), "Callback already configured");
        address callback_ = _address("SINGLE_CALLBACK_ADDR");
        vm.startBroadcast(signer);
        reactive.setCallback(callback_);
        vm.stopBroadcast();
        _report("Configured single callback", callback_);
    }
}
