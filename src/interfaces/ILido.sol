/// @title ILido
/// @notice Interface for Lido's stETH staking contract
interface ILido {
    /// @notice Submit ETH to the Lido staking pool
    /// @return Amount of stETH minted
    function submit(uint256 _amount) external returns (uint256);

    /// @notice Returns the current conversion rate between ETH and stETH
    /// @return The current conversion rate, scaled by 10^27
    function getPooledEthByShares(uint256 _sharesAmount) external view returns (uint256);

    /// @notice Total amount of ETH controlled by the protocol
    function getTotalPooledEther() external view returns (uint256);

    /// @notice Total amount of shares in the protocol
    function getTotalShares() external view returns (uint256);
}
