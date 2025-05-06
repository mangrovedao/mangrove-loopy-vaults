pragma solidity ^0.8.19;

/// @title IAaveOracle
/// @notice Interface for Aave V3 Oracle contract
interface IAaveOracle {
    function getAssetPrice(address) external view returns (uint256);
}
