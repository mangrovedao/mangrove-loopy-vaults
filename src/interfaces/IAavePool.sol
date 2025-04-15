/// @title IAavePool
/// @notice Interface for Aave V3 Pool contract
interface IAavePool {
    /// @notice Supplies an amount of asset to the protocol as collateral
    /// @param asset The address of the underlying asset to supply
    /// @param amount The amount to be supplied
    /// @param onBehalfOf The address that will receive the aTokens
    /// @param referralCode Code used to register the integrator originating the operation
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Withdraws an amount of asset from the protocol
    /// @param asset The address of the underlying asset to withdraw
    /// @param amount The amount to be withdrawn (type(uint256).max for everything)
    /// @param to The address that will receive the underlying
    /// @return The final amount withdrawn
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Borrows an amount of asset
    /// @param asset The address of the underlying asset to borrow
    /// @param amount The amount to be borrowed
    /// @param interestRateMode The interest rate mode (1 for stable, 2 for variable)
    /// @param referralCode Code used to register the integrator originating the operation
    /// @param onBehalfOf The address that will receive the borrowed funds
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    )
        external;

    /// @notice Repays a borrowed amount of asset
    /// @param asset The address of the borrowed underlying asset
    /// @param amount The amount to be repaid (type(uint256).max for everything)
    /// @param interestRateMode The interest rate mode (1 for stable, 2 for variable)
    /// @param onBehalfOf The address of the user who will get his debt reduced
    /// @return The final amount repaid
    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256);

    /// @notice Returns the user account data across all the reserves
    /// @param user The address of the user
    /// @return totalCollateralBase The total collateral in the base currency
    /// @return totalDebtBase The total debt in the base currency
    /// @return availableBorrowsBase The borrowing power left of the user
    /// @return currentLiquidationThreshold The liquidation threshold of the user
    /// @return ltv The loan to value of the user
    /// @return healthFactor The current health factor of the user
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}
