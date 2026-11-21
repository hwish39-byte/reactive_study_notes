// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice One-shot stop-loss monitor. Deploy first, then bind the callback once.
contract UniswapDemoStopOrderReactive is AbstractReactive {
    event CallbackConfigured(address indexed callback);
    event CallbackSent();
    event Done();

    uint256 private constant SYNC_TOPIC = uint256(keccak256("Sync(uint112,uint112)"));
    uint256 private constant STOP_TOPIC = uint256(keccak256("Stop(address,address,address,uint256[])"));
    uint64 private constant CALLBACK_GAS_LIMIT = 1000000;

    address public immutable owner;
    uint256 public immutable destinationChainId;
    address public immutable pair;
    address public immutable client;
    bool public immutable token0;
    uint256 public immutable coefficient;
    uint256 public immutable threshold;
    address public stop_order;
    bool public triggered;
    bool public done;

    constructor(
        uint256 chainId_,
        address pair_,
        address client_,
        bool token0_,
        uint256 coefficient_,
        uint256 threshold_
    ) payable {
        require(chainId_ != 0 && pair_ != address(0) && client_ != address(0), "Invalid order");
        require(coefficient_ > 0 && threshold_ > 0, "Invalid price parameters");
        owner = msg.sender;
        destinationChainId = chainId_;
        pair = pair_;
        client = client_;
        token0 = token0_;
        coefficient = coefficient_;
        threshold = threshold_;
    }

    /// @notice Call after deploying the callback with this reactive contract as its authorized sender.
    function setCallback(address callback_) external {
        require(msg.sender == owner, "Only owner");
        require(stop_order == address(0) && callback_ != address(0), "Invalid callback configuration");
        stop_order = callback_;
        SYSTEM.subscribe(destinationChainId, pair, SYNC_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(destinationChainId, callback_, STOP_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit CallbackConfigured(callback_);
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (done || stop_order == address(0) || log_.chainId != destinationChainId) return;

        if (log_.contractAddress == stop_order && log_.topic0 == STOP_TOPIC && log_.opCode == 4) {
            if (triggered && log_.topic1 == uint256(uint160(pair)) && log_.topic2 == uint256(uint160(client))) {
                // The sell token is in topic3; validate the direction on the destination before emitting Stop.
                done = true;
                SYSTEM.unsubscribe(
                    destinationChainId, pair, SYNC_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
                SYSTEM.unsubscribe(
                    destinationChainId, stop_order, STOP_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
                emit Done();
            }
        } else if (log_.contractAddress == pair && log_.topic0 == SYNC_TOPIC && log_.opCode == 1) {
            if (triggered || log_.data.length != 64) return;
            (uint112 reserve0, uint112 reserve1) = abi.decode(log_.data, (uint112, uint112));
            if (reserve0 == 0 || reserve1 == 0) return;
            uint256 price =
                token0 ? uint256(reserve1) * coefficient / reserve0 : uint256(reserve0) * coefficient / reserve1;
            if (price > threshold) return;

            triggered = true;
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: destinationChainId,
                    recipient: stop_order,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: abi.encodeWithSignature(
                        "stop(address,address,address,bool,uint256,uint256)",
                        address(0),
                        pair,
                        client,
                        token0,
                        coefficient,
                        threshold
                    )
                })
            );
            emit CallbackSent();
        }
    }
}
