// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ISwapModule {
    function swap(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256);
    function swapExactAmountOut(address tokenIn, address tokenOut, uint256 amountOut) external returns (uint256);
    function previewSwap(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256);
}
