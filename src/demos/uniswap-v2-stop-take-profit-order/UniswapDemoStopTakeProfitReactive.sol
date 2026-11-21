// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import "@reactive/src/base/AbstractReactive.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PersonalStopOrderReactive
 * @notice Personal reactive smart contract for monitoring stop orders
 * @dev Each user deploys their own instance paired with PersonalStopOrderCallback
 */
contract UniswapDemoStopTakeProfitReactive is AbstractReactive {
    // Events
    event OrderTracked(address indexed pair, uint256 indexed orderId);

    event OrderUntracked(address indexed pair, uint256 indexed orderId);

    event PairSubscribed(address indexed pair);

    event PairUnsubscribed(address indexed pair);

    event ExecutionTriggered(uint256 indexed orderId, address indexed pair, bool priceConditionMet);

    event ProcessingError(string reason, uint256 orderId);

    event ThresholdCheck(
        uint256 indexed orderId, uint256 calculated, uint256 threshold, bool conditionMet, bool sellToken0
    );

    // Constants
    uint256 public immutable destinationChainId;
    uint256 private constant UNISWAP_V2_SYNC_TOPIC_0 =
        0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1;
    uint256 private constant STOP_ORDER_CREATED_TOPIC_0 =
        0xc617c0f87fe14fdefff1476f1b4c2c15c9492ea39a9c2e19d4401bf09fbb06a8; // keccak256("StopOrderCreated(address,uint256,bool,address,address,uint256,uint256,uint256,uint8)")
    uint256 private constant STOP_ORDER_CANCELLED_TOPIC_0 =
        0xad9e9b6169c70ec1a50cf90107a9621b005376a3aa8662130d414a541693149d; // keccak256("StopOrderCancelled(uint256)")
    uint256 private constant STOP_ORDER_EXECUTED_TOPIC_0 =
        0x90979f4e8ed6baf430ca253822dfbd281b8d2c27d7a5121b484b4bfcaca4297f; // keccak256("StopOrderExecuted(address,uint256,address,address,uint256,uint256)")
    uint256 private constant STOP_ORDER_PAUSED_TOPIC_0 =
        0x7c070b2e9334d802a093c6b4a80f124bf4ffc8a9af89d0dae72ab22309f96889; // keccak256("StopOrderPaused(uint256)")
    uint256 private constant STOP_ORDER_RESUMED_TOPIC_0 =
        0x310f8f7e10ddae556ab6ef7c362667de2c95fad69956c224c16aa058755669a7; // keccak256("StopOrderResumed(uint256)")
    uint64 private constant CALLBACK_GAS_LIMIT = 1000000;

    enum OrderType {
        StopLoss,
        TakeProfit
    }

    // Order status enum (mirrors the callback contract)
    enum OrderStatus {
        Active,
        Paused,
        Cancelled,
        Executed,
        Failed
    }

    // Reserves struct for Uniswap sync events
    struct Reserves {
        uint112 reserve0;
        uint112 reserve1;
    }

    // Order tracking struct
    struct TrackedOrder {
        uint256 id;
        address pair;
        bool sellToken0;
        uint256 coefficient;
        uint256 threshold;
        OrderType orderType;
        OrderStatus status;
        uint256 lastTriggeredAt;
        uint8 triggerCount;
    }

    // State variables
    address public immutable owner;
    address public stopOrderCallback;
    event CallbackConfigured(address indexed callback);

    // Order tracking
    mapping(uint256 => TrackedOrder) public trackedOrders;
    mapping(address => uint256[]) public pairOrders; // pair -> orderIds
    mapping(address => uint256) public pairOrderCount;
    mapping(address => bool) public subscribedPairs;

    // Constants for retry logic
    uint256 private constant TRIGGER_COOLDOWN = 300; // 5 minutes between triggers
    uint8 private constant MAX_TRIGGER_ATTEMPTS = 5;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this");
        _;
    }

    constructor(address _owner, uint256 chainId_) payable {
        require(_owner != address(0) && chainId_ != 0, "Invalid configuration");
        owner = _owner;
        destinationChainId = chainId_;
    }

    /// @notice Bind once after deploying the callback with this reactive contract's address.
    function setCallback(address callback_) external onlyOwner {
        require(stopOrderCallback == address(0) && callback_ != address(0), "Invalid callback configuration");
        stopOrderCallback = callback_;
        uint256[5] memory topics = [
            STOP_ORDER_CREATED_TOPIC_0,
            STOP_ORDER_CANCELLED_TOPIC_0,
            STOP_ORDER_EXECUTED_TOPIC_0,
            STOP_ORDER_PAUSED_TOPIC_0,
            STOP_ORDER_RESUMED_TOPIC_0
        ];
        for (uint256 i; i < topics.length; ++i) {
            SYSTEM.subscribe(
                destinationChainId, callback_, topics[i], REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
        emit CallbackConfigured(callback_);
    }

    // Main reaction function
    function react(LogRecord calldata log) external onlySystem {
        if (stopOrderCallback == address(0) || log.chainId != destinationChainId) return;
        if (log.contractAddress == stopOrderCallback) {
            _processStopOrderEvent(log);
        } else if (
            log.topic0 == UNISWAP_V2_SYNC_TOPIC_0 && log.opCode == 1 && log.data.length == 64
                && subscribedPairs[log.contractAddress]
        ) {
            _processSyncEvent(log);
        }
    }

    // Process stop order lifecycle events
    function _processStopOrderEvent(LogRecord calldata log) internal {
        if (log.topic0 == STOP_ORDER_CREATED_TOPIC_0 && log.opCode == 3 && log.data.length == 224) {
            _processOrderCreated(log);
        } else if (log.topic0 == STOP_ORDER_CANCELLED_TOPIC_0 && log.opCode == 2) {
            _processOrderCancelled(log);
        } else if (log.topic0 == STOP_ORDER_EXECUTED_TOPIC_0 && log.opCode == 3) {
            _processOrderExecuted(log);
        } else if (log.topic0 == STOP_ORDER_PAUSED_TOPIC_0 && log.opCode == 2) {
            _processOrderPaused(log);
        } else if (log.topic0 == STOP_ORDER_RESUMED_TOPIC_0 && log.opCode == 2) {
            _processOrderResumed(log);
        }
    }

    // Process order creation
    function _processOrderCreated(LogRecord calldata log) internal {
        // Extract data from event topics
        address pair = address(uint160(log.topic1));
        uint256 orderId = uint256(log.topic2);

        // Decode additional data from log.data
        (bool sellToken0,,,, uint256 coefficient, uint256 threshold, OrderType orderType) =
            abi.decode(log.data, (bool, address, address, uint256, uint256, uint256, OrderType));

        if (pair == address(0) || trackedOrders[orderId].pair != address(0)) return;

        // Track the order
        trackedOrders[orderId] = TrackedOrder({
            id: orderId,
            pair: pair,
            sellToken0: sellToken0,
            coefficient: coefficient,
            threshold: threshold,
            orderType: orderType,
            status: OrderStatus.Active,
            lastTriggeredAt: 0,
            triggerCount: 0
        });

        // Add to pair's order list
        pairOrders[pair].push(orderId);

        // Subscribe to pair if this is the first order
        if (pairOrderCount[pair] == 0) {
            _requestPairSubscription(pair, log.chainId);
        }

        pairOrderCount[pair]++;

        emit OrderTracked(pair, orderId);
    }

    // Process order cancellation
    function _processOrderCancelled(LogRecord calldata log) internal {
        uint256 orderId = uint256(log.topic1);

        if (trackedOrders[orderId].pair != address(0)) {
            address pair = trackedOrders[orderId].pair;
            trackedOrders[orderId].status = OrderStatus.Cancelled;

            _decrementPairCount(pair);

            emit OrderUntracked(pair, orderId);
        }
    }

    // Process order execution
    function _processOrderExecuted(LogRecord calldata log) internal {
        uint256 orderId = uint256(log.topic2);

        if (trackedOrders[orderId].pair != address(0)) {
            address pair = trackedOrders[orderId].pair;
            trackedOrders[orderId].status = OrderStatus.Executed;

            _decrementPairCount(pair);

            emit OrderUntracked(pair, orderId);
        }
    }

    // Process order pause
    function _processOrderPaused(LogRecord calldata log) internal {
        uint256 orderId = uint256(log.topic1);

        if (trackedOrders[orderId].pair != address(0)) {
            trackedOrders[orderId].status = OrderStatus.Paused;
        }
    }

    // Process order resume
    function _processOrderResumed(LogRecord calldata log) internal {
        uint256 orderId = uint256(log.topic1);

        if (trackedOrders[orderId].pair != address(0)) {
            trackedOrders[orderId].status = OrderStatus.Active;
        }
    }

    // Process Uniswap sync events - Core monitoring logic
    function _processSyncEvent(LogRecord calldata log) internal {
        address pair = log.contractAddress;
        Reserves memory reserves = abi.decode(log.data, (Reserves));
        if (reserves.reserve0 == 0 || reserves.reserve1 == 0) return;

        // Get all orders for this pair
        uint256[] storage orderIds = pairOrders[pair];

        for (uint256 i = 0; i < orderIds.length; i++) {
            uint256 orderId = orderIds[i];
            TrackedOrder storage order = trackedOrders[orderId];

            // Skip non-active orders
            if (order.status != OrderStatus.Active) {
                continue;
            }

            // Check trigger cooldown
            if (order.lastTriggeredAt > 0 && block.timestamp < order.lastTriggeredAt + TRIGGER_COOLDOWN) {
                continue;
            }

            // Check max trigger attempts
            if (order.triggerCount >= MAX_TRIGGER_ATTEMPTS) {
                order.status = OrderStatus.Failed;
                emit ProcessingError("Max retries exceeded", orderId);
                continue;
            }

            // Check if price condition is met
            bool shouldTrigger =
                _isPriceConditionMet(order.sellToken0, reserves, order.coefficient, order.threshold, order.orderType);

            // Emit detailed debug event
            uint256 calculated;
            if (order.sellToken0) {
                calculated = Math.mulDiv(uint256(reserves.reserve1), order.coefficient, uint256(reserves.reserve0));
            } else {
                calculated = Math.mulDiv(uint256(reserves.reserve0), order.coefficient, uint256(reserves.reserve1));
            }

            emit ThresholdCheck(orderId, calculated, order.threshold, shouldTrigger, order.sellToken0);

            if (shouldTrigger) {
                _triggerExecution(orderId, pair);
            }
        }
    }

    // Check if price condition is met based on order type
    function _isPriceConditionMet(
        bool sellToken0,
        Reserves memory reserves,
        uint256 coefficient,
        uint256 threshold,
        OrderType orderType // ADD THIS PARAMETER
    ) internal pure returns (bool) {
        uint256 currentPrice;

        if (sellToken0) {
            // Price of token0 in terms of token1
            currentPrice = Math.mulDiv(uint256(reserves.reserve1), coefficient, uint256(reserves.reserve0));
        } else {
            // Price of token1 in terms of token0
            currentPrice = Math.mulDiv(uint256(reserves.reserve0), coefficient, uint256(reserves.reserve1));
        }

        if (orderType == OrderType.StopLoss) {
            return currentPrice <= threshold; // Execute when price drops below threshold
        } else {
            return currentPrice >= threshold; // Execute when price rises above threshold
        }
    }

    // Trigger order execution
    function _triggerExecution(uint256 orderId, address pair) internal {
        TrackedOrder storage order = trackedOrders[orderId];

        // Update trigger tracking
        order.lastTriggeredAt = block.timestamp;
        order.triggerCount++;

        // Create callback payload
        bytes memory payload = abi.encodeWithSignature(
            "executeStopOrder(address,uint256)",
            address(0), // overwritten by the proxy with this reactive contract address
            orderId
        );

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: stopOrderCallback,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );

        emit ExecutionTriggered(orderId, pair, true);
    }

    // Omni supports changing subscriptions directly inside react().
    function _requestPairSubscription(address pair, uint256 chainId) internal {
        if (!subscribedPairs[pair]) {
            SYSTEM.subscribe(chainId, pair, UNISWAP_V2_SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            subscribedPairs[pair] = true;
            emit PairSubscribed(pair);
        }
    }

    function _requestPairUnsubscription(address pair, uint256 chainId) internal {
        if (subscribedPairs[pair]) {
            SYSTEM.unsubscribe(
                chainId, pair, UNISWAP_V2_SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            subscribedPairs[pair] = false;
            emit PairUnsubscribed(pair);
        }
    }

    // Decrement pair order count and unsubscribe if needed
    function _decrementPairCount(address pair) internal {
        if (pairOrderCount[pair] > 0) {
            pairOrderCount[pair]--;

            // Unsubscribe if no more active orders
            if (pairOrderCount[pair] == 0) {
                _requestPairUnsubscription(pair, destinationChainId);
            }
        }
    }

    // Emergency function to manually force subscription (owner only)
    function emergencySubscribeToPair(address pair, uint256 chainId) external onlyOwner {
        require(chainId == destinationChainId && pair != address(0), "Invalid subscription");
        SYSTEM.subscribe(chainId, pair, UNISWAP_V2_SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        subscribedPairs[pair] = true;
        emit PairSubscribed(pair);
    }

    // Emergency function to manually force unsubscription (owner only)
    function emergencyUnsubscribeFromPair(address pair, uint256 chainId) external onlyOwner {
        require(chainId == destinationChainId && pair != address(0), "Invalid subscription");
        SYSTEM.unsubscribe(chainId, pair, UNISWAP_V2_SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        subscribedPairs[pair] = false;
        emit PairUnsubscribed(pair);
    }

    function getActiveOrdersForPair(address pair) external view returns (uint256[] memory) {
        uint256[] storage allOrders = pairOrders[pair];
        uint256 activeCount = 0;

        // Count active orders
        for (uint256 i = 0; i < allOrders.length; i++) {
            if (trackedOrders[allOrders[i]].status == OrderStatus.Active) {
                activeCount++;
            }
        }

        // Build active orders array
        uint256[] memory activeOrders = new uint256[](activeCount);
        uint256 index = 0;

        for (uint256 i = 0; i < allOrders.length; i++) {
            if (trackedOrders[allOrders[i]].status == OrderStatus.Active) {
                activeOrders[index] = allOrders[i];
                index++;
            }
        }

        return activeOrders;
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient address");
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }

    function rescueAllERC20(address token, address to) external onlyOwner {
        require(to != address(0), "Invalid recipient address");
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No tokens to rescue");
        SafeERC20.safeTransfer(IERC20(token), to, balance);
    }

    // Emergency withdrawal functions - only deployer can call
    function withdrawETH(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient ETH balance");

        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function withdrawAllETH() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");

        (bool success,) = payable(msg.sender).call{value: balance}("");
        require(success, "ETH transfer failed");
    }
}
