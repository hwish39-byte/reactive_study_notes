// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";

contract TransferMonitor is AbstractReactive {
    uint256 public constant ORIGIN_CHAIN_ID = 11155111;
    uint256 public constant TRANSFER_TOPIC = uint256(keccak256("Transfer(address,address,uint256)"));
    address public immutable token;
    uint256 public immutable maxCount;
    uint256 public count;
    uint256 public lastOriginTxHash;
    bool public subscribed;

    event TransferObserved(
        address indexed from, address indexed to, uint256 amount, uint256 originTxHash
    );
    event MonitoringStopped(uint256 count);

    constructor(address token_, uint256 maxCount_) payable {
        require(token_ != address(0), "zero token");
        require(maxCount_ > 0, "zero limit");
        require(msg.value > 0, "fund at deployment");
        token = token_;
        maxCount = maxCount_;
        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID, token_, TRANSFER_TOPIC,
            REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        subscribed = true;
    }

    function react(LogRecord calldata log_) external override onlySystem {
        if (!subscribed || count >= maxCount) return;
        if (log_.chainId != ORIGIN_CHAIN_ID || log_.contractAddress != token) return;
        if (log_.topic0 != TRANSFER_TOPIC || log_.opCode != 3 || log_.data.length != 32) return;

        uint256 amount = abi.decode(log_.data, (uint256));
        lastOriginTxHash = log_.txHash;
        count++;
        emit TransferObserved(
            address(uint160(log_.topic1)), address(uint160(log_.topic2)), amount, log_.txHash
        );

        if (count == maxCount) {
            SYSTEM.unsubscribe(
                ORIGIN_CHAIN_ID, token, TRANSFER_TOPIC,
                REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            subscribed = false;
            emit MonitoringStopped(count);
        }
    }
}
