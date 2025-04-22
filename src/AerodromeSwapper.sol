// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

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
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({ from: tokenIn, to: tokenOut, stable: false, factory: factory });
        amountOut = router.swapExactTokensForTokens(amountIn, 0, routes, address(this), block.timestamp)[0];
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        return amountOut;
    }
}
