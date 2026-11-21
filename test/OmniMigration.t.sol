// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {UniswapDemoStopOrderReactive} from "../src/demos/uniswap-v2-stop-order/UniswapDemoStopOrderReactive.sol";
import {UniswapDemoStopOrderCallback} from "../src/demos/uniswap-v2-stop-order/UniswapDemoStopOrderCallback.sol";
import {
    UniswapDemoStopTakeProfitReactive
} from "../src/demos/uniswap-v2-stop-take-profit-order/UniswapDemoStopTakeProfitReactive.sol";
import {
    UniswapDemoStopTakeProfitCallback
} from "../src/demos/uniswap-v2-stop-take-profit-order/UniswapDemoStopTakeProfitCallback.sol";

contract MockSystem {
    uint256 public subscriptions;
    uint256 public unsubscriptions;
    uint256 public requests;
    address public requester;
    uint256 public lastSubscribedChainId;
    uint256 public lastUnsubscribedChainId;
    ISystemContract.CallbackConfiguration_V_1_0 private last;

    function subscribe(uint256 chainId, address, uint256, uint256, uint256, uint256) external {
        lastSubscribedChainId = chainId;
        ++subscriptions;
    }

    function unsubscribe(uint256 chainId, address, uint256, uint256, uint256, uint256) external {
        lastUnsubscribedChainId = chainId;
        ++unsubscriptions;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 calldata config) external {
        last = config;
        requester = msg.sender;
        ++requests;
    }

    function configuration() external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return last;
    }
}

contract MockToken is ERC20 {
    constructor() ERC20("Test", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPair {
    address public token0;
    address public token1;

    constructor(address a, address b) {
        token0 = a;
        token1 = b;
    }

    function getReserves() external pure returns (uint112, uint112, uint32) {
        return (10000, 7000, 0);
    }
}

contract MockRouter {
    function swapExactTokensForTokens(uint256 amount, uint256, address[] calldata path, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        require(MockToken(path[0]).transferFrom(msg.sender, address(this), amount), "Mock transfer failed");
        MockToken(path[1]).mint(to, amount);
        amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;
    }
}

contract OmniMigrationTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant PROXY = address(0x1234);
    address constant ATTACKER = address(0xBAD);
    uint256 constant CHAIN = 11155111;
    MockSystem system;
    MockToken sell;
    MockToken buy;
    MockPair pair;
    MockRouter router;
    UniswapDemoStopOrderReactive single;
    UniswapDemoStopOrderCallback singleCallback;
    UniswapDemoStopTakeProfitReactive multi;
    UniswapDemoStopTakeProfitCallback multiCallback;

    function setUp() public {
        MockSystem implementation = new MockSystem();
        vm.etch(SYSTEM, address(implementation).code);
        system = MockSystem(SYSTEM);
        sell = new MockToken();
        buy = new MockToken();
        pair = new MockPair(address(sell), address(buy));
        router = new MockRouter();
        single = new UniswapDemoStopOrderReactive(CHAIN, address(pair), address(this), true, 10000, 8000);
        singleCallback = new UniswapDemoStopOrderCallback(IPayable(payable(PROXY)), address(single), address(router));
        multi = new UniswapDemoStopTakeProfitReactive(address(this), CHAIN);
        multiCallback = new UniswapDemoStopTakeProfitCallback(
            address(this), IPayable(payable(PROXY)), address(multi), address(router)
        );
        single.setCallback(address(singleCallback));
        multi.setCallback(address(multiCallback));
        sell.mint(address(this), 10000);
    }

    function syncLog() internal view returns (IReactive.LogRecord memory log_) {
        log_.chainId = CHAIN;
        log_.contractAddress = address(pair);
        log_.topic0 = uint256(keccak256("Sync(uint112,uint112)"));
        log_.opCode = 1;
        log_.data = abi.encode(uint112(10000), uint112(7000));
    }

    function createdLog(uint256 orderId, uint8 orderType) internal view returns (IReactive.LogRecord memory log_) {
        log_.chainId = CHAIN;
        log_.contractAddress = address(multiCallback);
        log_.topic0 =
            uint256(keccak256("StopOrderCreated(address,uint256,bool,address,address,uint256,uint256,uint256,uint8)"));
        log_.topic1 = uint256(uint160(address(pair)));
        log_.topic2 = orderId;
        log_.opCode = 3;
        log_.data =
            abi.encode(true, address(sell), address(buy), uint256(1000), uint256(10000), uint256(8000), orderType);
    }

    function testReactRejectsForgedLogs() public {
        IReactive.LogRecord memory log_ = syncLog();
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM));
        single.react(log_);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM));
        multi.react(log_);
    }

    function testConfigurationIsOwnerOnlyAndOneTime() public {
        UniswapDemoStopOrderReactive other =
            new UniswapDemoStopOrderReactive(CHAIN, address(pair), address(this), true, 10000, 8000);
        vm.prank(ATTACKER);
        vm.expectRevert("Only owner");
        other.setCallback(address(singleCallback));
        vm.prank(ATTACKER);
        vm.expectRevert("Only owner can call this");
        multi.setCallback(address(multiCallback));
        vm.expectRevert("Invalid callback configuration");
        single.setCallback(address(singleCallback));
        vm.expectRevert("Invalid callback configuration");
        multi.setCallback(address(multiCallback));
    }

    function testSingleRequestsTypedCallbackAndCompletes() public {
        IReactive.LogRecord memory log_ = syncLog();
        vm.prank(SYSTEM);
        single.react(log_);
        ISystemContract.CallbackConfiguration_V_1_0 memory config = system.configuration();
        assertEq(config.chainId, CHAIN);
        assertEq(config.recipient, address(singleCallback));
        assertEq(system.requester(), address(single));
        assertEq(
            config.payload,
            abi.encodeWithSignature(
                "stop(address,address,address,bool,uint256,uint256)",
                address(0),
                address(pair),
                address(this),
                true,
                uint256(10000),
                uint256(8000)
            )
        );
        vm.prank(SYSTEM);
        single.react(log_);
        assertEq(system.requests(), 1);
        log_.contractAddress = address(singleCallback);
        log_.topic0 = uint256(keccak256("Stop(address,address,address,uint256[])"));
        log_.topic1 = uint256(uint160(address(pair)));
        log_.topic2 = uint256(uint160(address(this)));
        log_.topic3 = uint256(uint160(address(sell)));
        log_.opCode = 4;
        vm.prank(SYSTEM);
        single.react(log_);
        assertTrue(single.done());
        assertEq(system.unsubscriptions(), 2);
        vm.prank(SYSTEM);
        single.react(syncLog());
        assertEq(system.requests(), 1);
    }

    function testSingleIgnoresWrongChainEmitterTopicAndShape() public {
        IReactive.LogRecord memory log_ = syncLog();
        log_.chainId = 1;
        vm.prank(SYSTEM);
        single.react(log_);
        log_ = syncLog();
        log_.contractAddress = ATTACKER;
        vm.prank(SYSTEM);
        single.react(log_);
        log_ = syncLog();
        log_.topic0 = 0;
        vm.prank(SYSTEM);
        single.react(log_);
        log_ = syncLog();
        log_.opCode = 2;
        vm.prank(SYSTEM);
        single.react(log_);
        log_ = syncLog();
        log_.data = hex"00";
        vm.prank(SYSTEM);
        single.react(log_);
        assertEq(system.requests(), 0);
    }

    function testMultiSubscribesDirectlyRequestsAndUnsubscribes() public {
        IReactive.LogRecord memory log_ = createdLog(0, 0);
        vm.prank(SYSTEM);
        multi.react(log_);
        assertTrue(multi.subscribedPairs(address(pair)));
        assertEq(multi.pairOrderCount(address(pair)), 1);
        assertEq(system.requests(), 0); // No self-callback for subscriptions.
        vm.prank(SYSTEM);
        multi.react(syncLog());
        ISystemContract.CallbackConfiguration_V_1_0 memory config = system.configuration();
        assertEq(config.chainId, CHAIN);
        assertEq(config.recipient, address(multiCallback));
        assertEq(config.payload, abi.encodeWithSignature("executeStopOrder(address,uint256)", address(0), uint256(0)));
        log_.topic0 = uint256(keccak256("StopOrderExecuted(address,uint256,address,address,uint256,uint256)"));
        log_.data = abi.encode(address(sell), address(buy), uint256(1000), uint256(700));
        vm.prank(SYSTEM);
        multi.react(log_);
        assertFalse(multi.subscribedPairs(address(pair)));
        assertEq(multi.pairOrderCount(address(pair)), 0);
    }

    function testMultiTakeProfitUsesOppositeComparison() public {
        IReactive.LogRecord memory log_ = createdLog(0, 1);
        vm.prank(SYSTEM);
        multi.react(log_);
        vm.prank(SYSTEM);
        multi.react(syncLog());
        assertEq(system.requests(), 0);
        log_ = syncLog();
        log_.data = abi.encode(uint112(10000), uint112(12000));
        vm.prank(SYSTEM);
        multi.react(log_);
        assertEq(system.requests(), 1);
    }

    function testSingleCallbackRejectsDirectCall() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), PROXY));
        singleCallback.stop(address(single), address(pair), address(this), true, 10000, 8000);
    }

    function testSingleCallbackRejectsWrongReactiveThroughProxy() public {
        vm.prank(PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, ATTACKER, address(single))
        );
        singleCallback.stop(ATTACKER, address(pair), address(this), true, 10000, 8000);
    }

    function testMultiCallbackRejectsDirectCall() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), PROXY));
        multiCallback.executeStopOrder(address(multi), 0);
    }

    function testMultiCallbackRejectsWrongReactiveThroughProxy() public {
        vm.prank(PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, ATTACKER, address(multi))
        );
        multiCallback.executeStopOrder(ATTACKER, 0);
    }

    function testAuthorizedSingleCallbackExecutesSwap() public {
        sell.approve(address(singleCallback), 1000);
        vm.prank(PROXY);
        singleCallback.stop(address(single), address(pair), address(this), true, 10000, 8000);
        assertEq(sell.balanceOf(address(this)), 9000);
        assertEq(buy.balanceOf(address(this)), 1000);
    }

    function testAuthorizedMultiCallbackExecutesSwap() public {
        sell.approve(address(multiCallback), 1000);
        multiCallback.createStopOrder(
            address(pair), true, 1000, 10000, 8000, UniswapDemoStopTakeProfitCallback.OrderType.StopLoss
        );
        vm.prank(PROXY);
        multiCallback.executeStopOrder(address(multi), 0);
        assertEq(multiCallback.getActiveOrders().length, 0);
        assertEq(buy.balanceOf(address(this)), 1000);
    }

    function testSepoliaChainIdUsedForLifecyclePairCallbackAndUnsubscribe() public {
        assertEq(multi.destinationChainId(), 11155111);
        assertEq(system.lastSubscribedChainId(), 11155111);
        IReactive.LogRecord memory log_ = createdLog(0, 0);
        log_.chainId = 1;
        vm.prank(SYSTEM);
        multi.react(log_);
        assertEq(multi.pairOrderCount(address(pair)), 0);
        log_.chainId = CHAIN;
        vm.prank(SYSTEM);
        multi.react(log_);
        assertEq(system.lastSubscribedChainId(), 11155111);
        log_ = syncLog();
        log_.chainId = 1;
        vm.prank(SYSTEM);
        multi.react(log_);
        assertEq(system.requests(), 0);
        log_.chainId = CHAIN;
        vm.prank(SYSTEM);
        multi.react(log_);
        assertEq(system.configuration().chainId, 11155111);
        log_ = createdLog(0, 0);
        log_.topic0 = uint256(keccak256("StopOrderCancelled(uint256)"));
        log_.topic1 = 0;
        log_.opCode = 2;
        log_.data = "";
        vm.prank(SYSTEM);
        multi.react(log_);
        assertEq(system.lastUnsubscribedChainId(), 11155111);
    }

    function testPausedOrderDoesNotTriggerAndResumedOrderDoes() public {
        IReactive.LogRecord memory log_ = createdLog(0, 0);
        vm.prank(SYSTEM);
        multi.react(log_);
        log_.topic0 = uint256(keccak256("StopOrderPaused(uint256)"));
        log_.topic1 = 0;
        log_.opCode = 2;
        log_.data = "";
        vm.prank(SYSTEM);
        multi.react(log_);
        vm.prank(SYSTEM);
        multi.react(syncLog());
        assertEq(system.requests(), 0);
        log_.topic0 = uint256(keccak256("StopOrderResumed(uint256)"));
        vm.prank(SYSTEM);
        multi.react(log_);
        vm.prank(SYSTEM);
        multi.react(syncLog());
        assertEq(system.requests(), 1);
    }

    function testCancelOnlyUnsubscribesAfterLastOrder() public {
        IReactive.LogRecord memory log_ = createdLog(0, 0);
        vm.prank(SYSTEM);
        multi.react(log_);
        log_ = createdLog(1, 0);
        vm.prank(SYSTEM);
        multi.react(log_);
        assertEq(multi.pairOrderCount(address(pair)), 2);
        log_.topic0 = uint256(keccak256("StopOrderCancelled(uint256)"));
        log_.topic1 = 0;
        log_.opCode = 2;
        log_.data = "";
        vm.prank(SYSTEM);
        multi.react(log_);
        assertTrue(multi.subscribedPairs(address(pair)));
        assertEq(multi.pairOrderCount(address(pair)), 1);
        log_.topic1 = 1;
        vm.prank(SYSTEM);
        multi.react(log_);
        assertFalse(multi.subscribedPairs(address(pair)));
        assertEq(multi.pairOrderCount(address(pair)), 0);
    }

    function testRetryRequiresCooldownAndAnotherSync() public {
        IReactive.LogRecord memory log_ = createdLog(0, 0);
        vm.prank(SYSTEM);
        multi.react(log_);
        vm.prank(SYSTEM);
        multi.react(syncLog());
        assertEq(system.requests(), 1);
        vm.prank(SYSTEM);
        multi.react(syncLog());
        assertEq(system.requests(), 1);
        vm.warp(block.timestamp + 300);
        assertEq(system.requests(), 1);
        vm.prank(SYSTEM);
        multi.react(syncLog());
        assertEq(system.requests(), 2);
    }
}
