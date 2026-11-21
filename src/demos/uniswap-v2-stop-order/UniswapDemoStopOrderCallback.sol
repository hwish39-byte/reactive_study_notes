// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.29;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

struct Reserves {
    uint112 reserve0;
    uint112 reserve1;
}

contract UniswapDemoStopOrderCallback is AbstractCallback {
    event Stop(address indexed pair, address indexed client, address indexed token, uint256[] tokens);

    IUniswapV2Router02 private router;

    uint256 private constant DEADLINE = 2707391655;

    constructor(IPayable _callbackProxy, address _reactive, address _router)
        payable
        AbstractCallback(_callbackProxy, _reactive)
    {
        require(address(_callbackProxy) != address(0) && _reactive != address(0), "Invalid callback authorization");
        router = IUniswapV2Router02(_router);
    }

    function stop(
        address reactive_,
        address pair,
        address client,
        bool is_token0,
        uint256 coefficient,
        uint256 threshold
    ) external onlyServiceProvider onlyCallbackSender(reactive_) {
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        require(
            below_threshold(is_token0, Reserves({reserve0: reserve0, reserve1: reserve1}), coefficient, threshold),
            "Rate above threshold"
        );
        address token_sell = is_token0 ? token0 : token1;
        address token_buy = is_token0 ? token1 : token0;
        uint256 allowance = IERC20(token_sell).allowance(client, address(this));
        require(allowance > 0, "No allowance");
        require(IERC20(token_sell).balanceOf(client) >= allowance, "Insufficient funds");
        assert(IERC20(token_sell).transferFrom(client, address(this), allowance));
        assert(IERC20(token_sell).approve(address(router), allowance));
        address[] memory path = new address[](2);
        path[0] = token_sell;
        path[1] = token_buy;
        uint256[] memory tokens = router.swapExactTokensForTokens(allowance, 0, path, address(this), DEADLINE);
        assert(IERC20(token_buy).transfer(client, tokens[1]));
        emit Stop(pair, client, token_sell, tokens);
    }

    function below_threshold(bool token0, Reserves memory sync, uint256 coefficient, uint256 threshold)
        internal
        pure
        returns (bool)
    {
        if (token0) {
            return (sync.reserve1 * coefficient) / sync.reserve0 <= threshold;
        } else {
            return (sync.reserve0 * coefficient) / sync.reserve1 <= threshold;
        }
    }
}
