// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {DeployStopOrder} from "../script/DeployStopOrder.s.sol";
import {DeployStopTakeProfit} from "../script/DeployStopTakeProfit.s.sol";
import {MockSystem} from "./OmniMigration.t.sol";
import {UniswapDemoStopOrderReactive} from "../src/demos/uniswap-v2-stop-order/UniswapDemoStopOrderReactive.sol";
import {UniswapDemoStopOrderCallback} from "../src/demos/uniswap-v2-stop-order/UniswapDemoStopOrderCallback.sol";
import {
    UniswapDemoStopTakeProfitReactive
} from "../src/demos/uniswap-v2-stop-take-profit-order/UniswapDemoStopTakeProfitReactive.sol";
import {
    UniswapDemoStopTakeProfitCallback
} from "../src/demos/uniswap-v2-stop-take-profit-order/UniswapDemoStopTakeProfitCallback.sol";

contract DeploymentScriptsTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant REACTIVE_SIGNER = address(0xA11CE);
    address constant DESTINATION_SIGNER = address(0xB0B);
    address constant CLIENT = address(0xCAFE);
    address constant PROXY = address(0x1234);
    address constant ROUTER = address(0x5678);
    uint256 constant REACTIVE_CHAIN = 5318007;
    uint256 constant SEPOLIA_CHAIN = 11155111;
    DeployStopOrder singleScript;
    DeployStopTakeProfit multiScript;

    function setUp() public {
        vm.chainId(REACTIVE_CHAIN);
        MockSystem implementation = new MockSystem();
        vm.etch(SYSTEM, address(implementation).code);
        vm.etch(PROXY, hex"00");
        vm.etch(ROUTER, hex"00");
        vm.deal(REACTIVE_SIGNER, 10 ether);
        vm.deal(DESTINATION_SIGNER, 10 ether);
        vm.setEnv("REACTIVE_CHAIN_ID", "5318007");
        vm.setEnv("DESTINATION_CHAIN_ID", "11155111");
        vm.setEnv("REACTIVE_DEPLOYER", vm.toString(REACTIVE_SIGNER));
        vm.setEnv("DESTINATION_DEPLOYER", vm.toString(DESTINATION_SIGNER));
        vm.setEnv("CLIENT_WALLET", vm.toString(CLIENT));
        vm.setEnv("DESTINATION_CALLBACK_PROXY_ADDR", vm.toString(PROXY));
        vm.setEnv("ROUTER_ADDR", vm.toString(ROUTER));
        vm.setEnv("PAIR_ADDR", vm.toString(address(0xBEEF)));
        vm.setEnv("REACTIVE_FUNDING_WEI", "100000000000000000");
        vm.setEnv("CALLBACK_FUNDING_WEI", "20000000000000000");
        vm.setEnv("SELL_TOKEN0", "true");
        vm.setEnv("PRICE_COEFFICIENT", "10000");
        vm.setEnv("STOP_LOSS_THRESHOLD", "8000");
        singleScript = new DeployStopOrder();
        multiScript = new DeployStopTakeProfit();
    }

    // Environment variables are process-wide, so run these script scenarios sequentially
    // in one test rather than racing setEnv() across parallel Forge tests.
    function testDeploymentFlowsAndPreflightChecks() public {
        uint256 snapshot = vm.snapshotState();
        _checkSingleDeploymentPhasesUseSignersFundsAndSepoliaId();
        assertTrue(vm.revertToState(snapshot));
        setUp();
        _checkMultiDeploymentPhasesSeparateReactiveOwnerFromClient();
        assertTrue(vm.revertToState(snapshot));
        setUp();
        _checkScriptsRejectWrongRpcChain();
        assertTrue(vm.revertToState(snapshot));
        setUp();
        _checkScriptsRejectMissingOmniSystemOrProxy();
        assertTrue(vm.revertToState(snapshot));
        setUp();
        _checkConfigureRejectsWrongOwner();
        assertTrue(vm.revertToState(snapshot));
        setUp();
        _checkConfigureRejectsMismatchedDestinationChainId();
    }

    function _checkSingleDeploymentPhasesUseSignersFundsAndSepoliaId() internal {
        UniswapDemoStopOrderReactive reactive = singleScript.deployReactive();
        assertEq(reactive.owner(), REACTIVE_SIGNER);
        assertEq(reactive.client(), CLIENT);
        assertEq(reactive.destinationChainId(), SEPOLIA_CHAIN);
        assertEq(address(reactive).balance, 0.1 ether);
        vm.setEnv("SINGLE_REACTIVE_ADDR", vm.toString(address(reactive)));
        vm.chainId(SEPOLIA_CHAIN);
        UniswapDemoStopOrderCallback callback_ = singleScript.deployCallback();
        assertEq(callback_._CALLBACK_SENDER(), address(reactive));
        assertEq(address(callback_._SERVICE_PROVIDER()), PROXY);
        assertEq(address(callback_).balance, 0.02 ether);
        vm.setEnv("SINGLE_CALLBACK_ADDR", vm.toString(address(callback_)));
        vm.chainId(REACTIVE_CHAIN);
        singleScript.configure();
        assertEq(reactive.stop_order(), address(callback_));
        assertEq(MockSystem(SYSTEM).subscriptions(), 2);
        assertEq(MockSystem(SYSTEM).lastSubscribedChainId(), SEPOLIA_CHAIN);
        vm.expectRevert("Callback already configured");
        singleScript.configure();
    }

    function _checkMultiDeploymentPhasesSeparateReactiveOwnerFromClient() internal {
        UniswapDemoStopTakeProfitReactive reactive = multiScript.deployReactive();
        assertEq(reactive.owner(), REACTIVE_SIGNER);
        assertEq(reactive.destinationChainId(), SEPOLIA_CHAIN);
        assertEq(address(reactive).balance, 0.1 ether);
        vm.setEnv("MULTI_REACTIVE_ADDR", vm.toString(address(reactive)));
        vm.chainId(SEPOLIA_CHAIN);
        UniswapDemoStopTakeProfitCallback callback_ = multiScript.deployCallback();
        assertEq(callback_.owner(), CLIENT);
        assertEq(callback_._CALLBACK_SENDER(), address(reactive));
        assertEq(address(callback_).balance, 0.02 ether);
        vm.setEnv("MULTI_CALLBACK_ADDR", vm.toString(address(callback_)));
        vm.chainId(REACTIVE_CHAIN);
        multiScript.configure();
        assertEq(reactive.stopOrderCallback(), address(callback_));
        assertEq(MockSystem(SYSTEM).subscriptions(), 5);
        assertEq(MockSystem(SYSTEM).lastSubscribedChainId(), SEPOLIA_CHAIN);
        vm.expectRevert("Callback already configured");
        multiScript.configure();
    }

    function _checkScriptsRejectWrongRpcChain() internal {
        vm.chainId(1);
        vm.expectRevert("Wrong Reactive RPC chain ID");
        singleScript.deployReactive();
        vm.expectRevert("Wrong Reactive RPC chain ID");
        multiScript.deployReactive();
        vm.expectRevert("Wrong destination RPC chain ID");
        singleScript.deployCallback();
        vm.expectRevert("Wrong destination RPC chain ID");
        multiScript.deployCallback();
    }

    function _checkScriptsRejectMissingOmniSystemOrProxy() internal {
        vm.etch(SYSTEM, "");
        vm.expectRevert("Omni system contract missing");
        singleScript.deployReactive();
        vm.expectRevert("Omni system contract missing");
        multiScript.deployReactive();
        vm.chainId(SEPOLIA_CHAIN);
        vm.etch(PROXY, "");
        vm.expectRevert("Callback proxy has no code");
        singleScript.deployCallback();
        vm.expectRevert("Callback proxy has no code");
        multiScript.deployCallback();
    }

    function _checkConfigureRejectsWrongOwner() internal {
        UniswapDemoStopOrderReactive single = singleScript.deployReactive();
        UniswapDemoStopTakeProfitReactive multi = multiScript.deployReactive();
        vm.setEnv("SINGLE_REACTIVE_ADDR", vm.toString(address(single)));
        vm.setEnv("MULTI_REACTIVE_ADDR", vm.toString(address(multi)));
        vm.setEnv("REACTIVE_DEPLOYER", vm.toString(DESTINATION_SIGNER));
        vm.expectRevert("Signer is not Reactive owner");
        singleScript.configure();
        vm.expectRevert("Signer is not Reactive owner");
        multiScript.configure();
    }

    function _checkConfigureRejectsMismatchedDestinationChainId() internal {
        UniswapDemoStopOrderReactive single = singleScript.deployReactive();
        UniswapDemoStopTakeProfitReactive multi = multiScript.deployReactive();
        vm.setEnv("SINGLE_REACTIVE_ADDR", vm.toString(address(single)));
        vm.setEnv("MULTI_REACTIVE_ADDR", vm.toString(address(multi)));
        vm.setEnv("DESTINATION_CHAIN_ID", "1");
        vm.expectRevert("Destination chain ID mismatch");
        singleScript.configure();
        vm.expectRevert("Destination chain ID mismatch");
        multiScript.configure();
    }
}
