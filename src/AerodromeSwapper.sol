// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IERC20, SafeERC20 } from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import { IAerodromeRouter } from "src/interfaces/IAerodromeRouter.sol";

contract AerodromeSwapper {
    using SafeERC20 for IERC20;

    IAerodromeRouter public immutable router;
    address public immutable factory;

    constructor(address _factory, address _router) {
        router = IAerodromeRouter(_router);
        factory = _factory;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 amountOut) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        IERC20(tokenIn).safeIncreaseAllowance(address(router), amountIn);

        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({ from: tokenIn, to: tokenOut, stable: false, factory: factory });
        amountOut = router.swapExactTokensForTokens(amountIn, 0, routes, address(this), block.timestamp)[1];
        IERC20(tokenIn).safeDecreaseAllowance(address(router), 0);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        return amountOut;
    }

    function swapExactAmountOut(address tokenIn, address tokenOut, uint256 amountOut) external returns (uint256) {
        // Get the amount of input tokens needed for the swap
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({ from: tokenIn, to: tokenOut, stable: false, factory: factory });

        // Calculate the amount of input tokens needed (with a safety margin)
        uint256 amountIn = previewSwap(tokenOut, tokenIn, amountOut);
        uint256 amountInWithMargin = (amountIn * 105) / 100; // Add 5% margin

        // Transfer tokens from user to this contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountInWithMargin);
        IERC20(tokenIn).safeIncreaseAllowance(address(router), amountInWithMargin);

        // Execute the swap
        uint256 amountOutReceived =
            router.swapExactTokensForTokens(amountInWithMargin, amountOut, routes, address(this), block.timestamp)[1];

        // Clean up allowance
        IERC20(tokenIn).safeDecreaseAllowance(address(router), 0);

        // Return unused input tokens
        uint256 unusedAmount = IERC20(tokenIn).balanceOf(address(this));
        if (unusedAmount > 0) {
            IERC20(tokenIn).safeTransfer(msg.sender, unusedAmount);
        }

        // Transfer output tokens to the user
        IERC20(tokenOut).safeTransfer(msg.sender, amountOutReceived);

        return amountInWithMargin - unusedAmount;
    }

    function previewSwap(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256 amountOut) {
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({ from: tokenIn, to: tokenOut, stable: false, factory: factory });
        return router.getAmountsOut(amountIn, routes)[1];
    }
}
