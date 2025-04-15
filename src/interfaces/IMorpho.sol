// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

/// @title IMorpho
/// @notice Interface for Morpho's core lending protocol
interface IMorpho {
    /// @notice Market ID type
    type Id is bytes32;

    /// @notice Market parameters struct
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        address lltv;
    }

    /// @notice Market state struct
    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    /// @notice Returns the market parameters for a given ID
    /// @param id The market ID
    /// @return The market parameters
    function idToMarketParams(Id id) external view returns (MarketParams memory);

    /// @notice Returns the market state for a given ID
    /// @param id The market ID
    /// @return The market state
    function market(Id id) external view returns (Market memory);

    /// @notice Accrues interest for a market
    /// @param marketParams The market parameters
    function accrueInterest(MarketParams calldata marketParams) external;

    /// @notice Returns the supply shares for a user in a market
    /// @param id The market ID
    /// @param user The user address
    /// @return The supply shares
    function supplyShares(Id id, address user) external view returns (uint256);

    /// @notice Returns the borrow shares for a user in a market
    /// @param id The market ID
    /// @param user The user address
    /// @return The borrow shares
    function borrowShares(Id id, address user) external view returns (uint256);

    /// @notice Supplies assets to a market
    /// @param marketParams The market parameters
    /// @param assets The amount of assets to supply
    /// @param shares The minimum amount of shares to receive
    /// @param onBehalf The address that will receive the supply position
    /// @param data Additional data
    /// @return supplyAssets The amount of assets supplied
    /// @return supplyShares The amount of shares received
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 supplyAssets, uint256 supplyShares);

    /// @notice Withdraws assets from a market
    /// @param marketParams The market parameters
    /// @param assets The amount of assets to withdraw
    /// @param shares The amount of shares to burn
    /// @param onBehalf The address that will have its supply position reduced
    /// @param receiver The address that will receive the withdrawn assets
    /// @return withdrawnAssets The amount of assets withdrawn
    /// @return withdrawnShares The amount of shares burned
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 withdrawnAssets, uint256 withdrawnShares);

    /// @notice Borrows assets from a market
    /// @param marketParams The market parameters
    /// @param assets The amount of assets to borrow
    /// @param shares The maximum amount of shares to receive
    /// @param onBehalf The address that will receive the borrow position
    /// @param receiver The address that will receive the borrowed assets
    /// @return borrowedAssets The amount of assets borrowed
    /// @return borrowedShares The amount of shares received
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 borrowedAssets, uint256 borrowedShares);

    /// @notice Repays a borrow position
    /// @param marketParams The market parameters
    /// @param assets The amount of assets to repay
    /// @param shares The amount of shares to burn
    /// @param onBehalf The address that will have its borrow position reduced
    /// @param data Additional data
    /// @return repaidAssets The amount of assets repaid
    /// @return repaidShares The amount of shares burned
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 repaidAssets, uint256 repaidShares);

    /// @notice Returns the expected supply assets for a user in a market
    /// @param marketParams The market parameters
    /// @param user The user address
    /// @return The expected supply assets
    function expectedSupplyAssets(MarketParams memory marketParams, address user) external view returns (uint256);

    /// @notice Returns the expected borrow assets for a user in a market
    /// @param marketParams The market parameters
    /// @param user The user address
    /// @return The expected borrow assets
    function expectedBorrowAssets(MarketParams memory marketParams, address user) external view returns (uint256);

    /// @notice Returns the expected market balances
    /// @param marketParams The market parameters
    /// @return totalSupplyAssets The expected total supply assets
    /// @return totalSupplyShares The expected total supply shares
    /// @return totalBorrowAssets The expected total borrow assets
    /// @return totalBorrowShares The expected total borrow shares
    function expectedMarketBalances(MarketParams memory marketParams) 
        external 
        view 
        returns (
            uint256 totalSupplyAssets, 
            uint256 totalSupplyShares, 
            uint256 totalBorrowAssets, 
            uint256 totalBorrowShares
        );
}