// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

// Token addresses on Base network
address constant WETH_BASE = 0x4200000000000000000000000000000000000006;
address constant USDC_BASE = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;
address constant ST_ETH_BASE = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
address constant WST_ETH_BASE = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;

// Token addresses on Arbitrum network
address constant WETH_ARBITRUM = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
address constant USDC_ARBITRUM = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
address constant ST_ETH_ARBITRUM = 0x5979D7b546E38E414F7E9822514be443A4800529;

uint256 constant _1_USDC = 1e6;
uint256 constant _1_USDCE = 1e6;

function getTokensList(string memory chain) pure returns (address[] memory) {
    if (keccak256(abi.encodePacked(chain)) == keccak256(abi.encodePacked("ARBITRUM"))) {
        address[] memory tokens = new address[](3);
        tokens[0] = USDC_ARBITRUM;
        tokens[1] = WETH_ARBITRUM;
        tokens[2] = ST_ETH_ARBITRUM;
    } else if (keccak256(abi.encodePacked(chain)) == keccak256(abi.encodePacked("BASE"))) {
        address[] memory tokens = new address[](4);
        tokens[0] = USDC_BASE;
        tokens[1] = WETH_BASE;
        tokens[2] = ST_ETH_BASE;
        tokens[3] = WST_ETH_BASE;
        return tokens;
    } else {
        revert("InvalidChain");
    }
}
