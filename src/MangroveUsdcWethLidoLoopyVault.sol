// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import { IAavePool } from "./interfaces/IAavePool.sol";
import { ILido } from "./interfaces/ILido.sol";
import { IMorpho } from "./interfaces/IMorpho.sol";
import { IERC20, SafeERC20 } from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin-contracts/utils/math/Math.sol";
import { BaseMangroveLoopyVault } from "src/base/BaseMangroveLoopyVault.sol";

/// @title MangroveUsdcWethLidoLoopyVault
/// @author Mangrove
/// @notice A looping vault that leverages USDC to borrow WETH, stakes in Lido, and uses stETH on Morpho to borrow more
/// WETH
/// @dev Inherits from BaseMangroveLoopyVault and implements looping strategy
contract MangroveUsdcWethLidoLoopyVault is BaseMangroveLoopyVault {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Events
    /// @notice Emitted when a loop iteration is performed
    /// @param iteration The iteration number
    /// @param wethBorrowed Amount of WETH borrowed in this iteration
    /// @param stEthReceived Amount of stETH received in this iteration
    event LoopIteration(uint256 indexed iteration, uint256 wethBorrowed, uint256 stEthReceived);

    /// @notice Emitted when the loop position is unwound
    /// @param iterations Number of iterations unwound
    /// @param totalWethRepaid Total amount of WETH repaid
    /// @param totalStEthRedeemed Total amount of stETH redeemed
    event UnwindLoop(uint256 iterations, uint256 totalWethRepaid, uint256 totalStEthRedeemed);

    /// @notice Emitted when a new max loop iterations value is set
    /// @param newMaxIterations The new maximum number of loop iterations
    event SetMaxIterations(uint256 newMaxIterations);

    /// @notice Emitted when a new target leverage is set
    /// @param newTargetLeverage The new target leverage multiplier
    event SetTargetLeverage(uint256 newTargetLeverage);

    // Errors
    /// @notice Thrown when trying to loop more than allowed iterations
    error MaxIterationsExceeded();

    /// @notice Thrown when leverage would exceed the maximum allowed
    error MaxLeverageExceeded();

    /// @notice Thrown when an operation fails with insufficient liquidity
    error InsufficientLiquidity();

    /// @notice Thrown when an operation would result in a health factor below minimum
    error HealthFactorTooLow();

    /// @notice Thrown when a Morpho market is not found
    error MarketNotFound();

    /* STORAGE */

    /// @notice Address of the USDC token
    IERC20 public immutable usdc;

    /// @notice Address of the WETH token
    IERC20 public immutable weth;

    /// @notice Address of the stETH token from Lido
    IERC20 public immutable stEth;

    /// @notice Lido staking contract for ETH
    ILido public immutable lido;

    /// @notice Aave lending pool contract
    IAavePool public immutable aavePool;

    /// @notice Morpho protocol contract
    IMorpho public immutable morpho;

    /// @notice Morpho market ID for stETH-WETH market
    IMorpho.Id public immutable morphoMarketId;

    /// @notice Maximum number of loop iterations allowed
    uint256 public maxIterations;

    /// @notice Target leverage multiplier (in basis points, e.g., 300 = 3x)
    uint256 public targetLeverage;

    /// @notice Minimum health factor to maintain (in basis points, e.g., 120 = 1.2)
    uint256 public constant MIN_HEALTH_FACTOR = 120;

    /// @notice Maximum leverage factor allowed (in basis points, e.g., 500 = 5x)
    uint256 public constant MAX_LEVERAGE = 500;

    /// @notice The basis points denominator (10000 = 100%)
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Current number of loop iterations active
    uint256 public currentIterations;

    /// @notice Total WETH borrowed across all iterations
    uint256 public totalWethBorrowed;

    /// @notice Total stETH held from all iterations
    uint256 public totalStEthHeld;

    /// @notice Constructs the MangroveUsdcWethLidoLoopyVault
    /// @param owner Address of the vault owner
    /// @param initialTimelock Initial timelock duration
    /// @param _usdc Address of the USDC token
    /// @param _weth Address of the WETH token
    /// @param _lido Address of the Lido staking contract
    /// @param _stEth Address of the stETH token
    /// @param _aavePool Address of the Aave lending pool
    /// @param _morpho Address of the Morpho protocol
    /// @param _morphoMarketId Morpho market ID for stETH-WETH market
    /// @param _maxIterations Maximum number of loop iterations allowed
    /// @param _targetLeverage Target leverage multiplier (in basis points)
    /// @param _name Name of the vault token
    /// @param _symbol Symbol of the vault token
    constructor(
        address owner,
        uint256 initialTimelock,
        address _usdc,
        address _weth,
        address _lido,
        address _stEth,
        address _aavePool,
        address _morpho,
        IMorpho.Id _morphoMarketId,
        uint256 _maxIterations,
        uint256 _targetLeverage,
        string memory _name,
        string memory _symbol
    )
        BaseMangroveLoopyVault(owner, initialTimelock, _usdc, _name, _symbol)
    {
        require(_maxIterations > 0, "Zero max iterations");
        require(_targetLeverage > 0, "Zero target leverage");
        require(_targetLeverage <= MAX_LEVERAGE, "Target leverage too high");

        usdc = IERC20(_usdc);
        weth = IERC20(_weth);
        lido = ILido(_lido);
        stEth = IERC20(_stEth);
        aavePool = IAavePool(_aavePool);
        morpho = IMorpho(_morpho);
        morphoMarketId = _morphoMarketId;
        maxIterations = _maxIterations;
        targetLeverage = _targetLeverage;

        // Verify that the market exists and has the correct tokens
        IMorpho.MarketParams memory params = morpho.idToMarketParams(morphoMarketId);
        require(params.loanToken == _weth, "Invalid loan token in Morpho market");
        require(params.collateralToken == _stEth, "Invalid collateral token in Morpho market");

        // Approve tokens for protocol interactions
        IERC20(_usdc).safeApprove(_aavePool, type(uint256).max);
        IERC20(_weth).safeApprove(_lido, type(uint256).max);
        IERC20(_weth).safeApprove(_aavePool, type(uint256).max);
        IERC20(_stEth).safeApprove(_morpho, type(uint256).max);
    }

    /// @notice Sets the maximum number of loop iterations
    /// @dev Only callable by the owner
    /// @param _maxIterations New maximum number of iterations
    function setMaxIterations(uint256 _maxIterations) external onlyOwner {
        require(_maxIterations > 0, "Zero max iterations");
        maxIterations = _maxIterations;
        emit SetMaxIterations(_maxIterations);
    }

    /// @notice Sets the target leverage multiplier
    /// @dev Only callable by the owner
    /// @param _targetLeverage New target leverage (in basis points)
    function setTargetLeverage(uint256 _targetLeverage) external onlyOwner {
        require(_targetLeverage > 0, "Zero target leverage");
        require(_targetLeverage <= MAX_LEVERAGE, "Target leverage too high");
        targetLeverage = _targetLeverage;
        emit SetTargetLeverage(_targetLeverage);
    }

    /// @inheritdoc BaseMangroveLoopyVault
    function maxLeverageFactor() public view override returns (uint256) {
        return MAX_LEVERAGE;
    }

    /// @inheritdoc BaseMangroveLoopyVault
    function currentLeverageFactor() public view override returns (uint256) {
        uint256 usdcValue = _getUsdcValue();
        if (usdcValue == 0) return 0;

        // Calculate total position value including borrowed assets
        uint256 totalPositionValue = usdcValue + _getStEthValueInUsdc();

        return totalPositionValue * BASIS_POINTS / usdcValue;
    }

    /// @notice Returns the total assets of the vault
    /// @dev Includes USDC balance held + USDC used as collateral + earned yield
    /// @return Total assets in USDC terms
    function totalAssets() public view override returns (uint256) {
        // Direct USDC balance held by the vault
        uint256 directUsdcBalance = usdc.balanceOf(address(this));

        // USDC supplied as collateral on Aave
        uint256 usdcCollateral = aavePool.getUserAccountData(address(this)).totalCollateralBase;

        // Value of stETH (minus the WETH debt) - this represents our earned yield
        uint256 netPositionValue = _getStEthValueInUsdc() - _getWethDebtInUsdc();

        return directUsdcBalance + usdcCollateral + netPositionValue;
    }

    /// @notice Executes a deposit into the vault and performs the looping strategy
    /// @param assets Amount of assets (USDC) to deposit
    /// @param receiver Address to receive the vault shares
    /// @return shares Amount of shares minted to the receiver
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        // Accrue fees before deposit
        uint256 newTotalAssets = _accrueFee();

        // Update lastTotalAssets to avoid inconsistent state in re-entrant context
        // It will be updated again after the deposit
        lastTotalAssets = newTotalAssets;

        // Calculate shares based on updated total assets
        shares = _convertToSharesWithTotals(assets, totalSupply(), newTotalAssets, Math.Rounding.Floor);

        // Do the standard ERC4626 deposit using super._deposit without fee accrual
        super._deposit(_msgSender(), receiver, assets, shares);

        // Execute the looping strategy
        _executeLoopStrategy();

        // Update lastTotalAssets after strategy execution
        _updateLastTotalAssets(totalAssets());

        return shares;
    }

    /// @notice Executes a withdrawal from the vault, unwinding the loop as needed
    /// @param assets Amount of assets (USDC) to withdraw
    /// @param receiver Address to receive the withdrawn assets
    /// @param owner Address that owns the shares
    /// @return shares Amount of shares burned from the owner
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        // Accrue fees before withdrawal
        uint256 newTotalAssets = _accrueFee();

        // Calculate shares based on updated total assets
        shares = _convertToSharesWithTotals(assets, totalSupply(), newTotalAssets, Math.Rounding.Ceil);

        // First unwind the loop if needed to free up assets
        if (assets > usdc.balanceOf(address(this))) {
            _unwindLoopAsNeeded(assets);
        }

        // Update lastTotalAssets to newTotalAssets minus assets being withdrawn
        _updateLastTotalAssets(newTotalAssets.zeroFloorSub(assets));

        // Do the standard ERC4626 withdrawal using super._withdraw without fee accrual
        super._withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    /// @notice Manually triggers rebalancing of the loop strategy
    /// @dev Can be called by allocators, curators, or owner to optimize the position
    function rebalance() external onlyAllocatorRole {
        // First accrue fees
        uint256 newTotalAssets = _accrueFee();

        // Update lastTotalAssets to avoid inconsistent state in re-entrant context
        lastTotalAssets = newTotalAssets;

        // Unwind the current loop position
        _unwindLoop();

        // Re-execute the loop strategy with current parameters
        _executeLoopStrategy();

        // Update lastTotalAssets after strategy execution
        _updateLastTotalAssets(totalAssets());
    }

    /// @notice Emergency function to unwind all loops
    /// @dev Can be called by guardian or owner in case of emergency
    function emergencyUnwind() external onlyGuardianRole {
        // First accrue fees
        uint256 newTotalAssets = _accrueFee();

        // Update lastTotalAssets to avoid inconsistent state in re-entrant context
        lastTotalAssets = newTotalAssets;

        // Unwind all loops
        _unwindLoop();

        // Update lastTotalAssets after unwinding
        _updateLastTotalAssets(totalAssets());
    }

    /// @notice Executes the looping strategy to leverage the position
    /// @dev Internal function that implements the core looping logic
    function _executeLoopStrategy() internal {
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (usdcBalance == 0) return;

        // Supply USDC to Aave as collateral
        aavePool.supply(address(usdc), usdcBalance, address(this), 0);

        // Calculate initial borrow capacity for WETH on Aave
        uint256 initialBorrowCapacity = _calculateBorrowCapacityAave();
        uint256 remainingBorrowCapacity = initialBorrowCapacity;

        // Calculate how much WETH to borrow based on target leverage
        uint256 targetBorrowAmount = usdcBalance * targetLeverage / BASIS_POINTS;
        uint256 borrowedSoFar = 0;

        // Start looping process
        for (uint256 i = 0; i < maxIterations && borrowedSoFar < targetBorrowAmount; i++) {
            // Calculate how much WETH to borrow in this iteration from Aave
            uint256 iterationBorrow = Math.min(
                remainingBorrowCapacity,
                (targetBorrowAmount - borrowedSoFar) / 2 // Divide by 2 since we'll borrow roughly same amount from
                    // Morpho
            );

            if (iterationBorrow == 0) break;

            // Step 1: Borrow WETH from Aave
            aavePool.borrow(address(weth), iterationBorrow, 2, 0, address(this));

            // Step 2: Stake WETH in Lido to get stETH
            uint256 stEthBefore = stEth.balanceOf(address(this));
            lido.submit(iterationBorrow);
            uint256 stEthReceived = stEth.balanceOf(address(this)) - stEthBefore;

            // Step 3: Supply stETH to Morpho as collateral
            IMorpho.MarketParams memory marketParams = morpho.idToMarketParams(morphoMarketId);
            (uint256 suppliedStEth,) = morpho.supply(
                marketParams,
                stEthReceived,
                0, // min shares
                address(this),
                ""
            );

            // Step 4: Borrow WETH from Morpho using stETH as collateral
            uint256 morphoBorrowCapacity = _calculateBorrowCapacityMorpho(marketParams);
            uint256 morphoBorrowAmount =
                Math.min(morphoBorrowCapacity, (targetBorrowAmount - borrowedSoFar - iterationBorrow));

            if (morphoBorrowAmount > 0) {
                (uint256 borrowedWeth,) = morpho.borrow(
                    marketParams,
                    morphoBorrowAmount,
                    type(uint256).max, // max shares
                    address(this),
                    address(this)
                );

                // Update tracking variables with Morpho borrowed amount
                borrowedSoFar += iterationBorrow + borrowedWeth;
                totalWethBorrowed += iterationBorrow + borrowedWeth;
            } else {
                // Update tracking variables with just Aave borrowed amount
                borrowedSoFar += iterationBorrow;
                totalWethBorrowed += iterationBorrow;
            }

            totalStEthHeld += stEthReceived;
            currentIterations++;

            // Calculate remaining borrow capacity on Aave for next iteration
            remainingBorrowCapacity = _calculateBorrowCapacityAave();

            emit LoopIteration(i + 1, iterationBorrow, stEthReceived);

            // Check health factor after each iteration
            uint256 healthFactor = _getCurrentHealthFactorAave();
            if (healthFactor < MIN_HEALTH_FACTOR * 100) {
                break;
            }
        }
    }

    /// @notice Unwinds the loop position completely
    /// @dev Repays all WETH debt and redeems all stETH
    function _unwindLoop() internal {
        if (currentIterations == 0) return;

        uint256 iterations = currentIterations;
        uint256 wethDebt = totalWethBorrowed;
        uint256 stEthHeld = totalStEthHeld;

        // Step 1: Repay WETH debt on Morpho
        IMorpho.MarketParams memory marketParams = morpho.idToMarketParams(morphoMarketId);
        uint256 morphoDebt = morpho.expectedBorrowAssets(marketParams, address(this));

        if (morphoDebt > 0) {
            // Ensure we have enough WETH to repay Morpho debt
            uint256 wethBalance = weth.balanceOf(address(this));
            if (wethBalance < morphoDebt) {
                // If we don't have enough WETH, borrow more from Aave temporarily
                aavePool.borrow(address(weth), morphoDebt - wethBalance, 2, 0, address(this));
            }

            // Repay the Morpho debt
            morpho.repay(
                marketParams,
                morphoDebt,
                0, // shares
                address(this),
                ""
            );
        }

        // Step 2: Withdraw stETH from Morpho
        uint256 morphoStEth = morpho.expectedSupplyAssets(marketParams, address(this));
        if (morphoStEth > 0) {
            morpho.withdraw(
                marketParams,
                type(uint256).max, // withdraw all
                0, // shares
                address(this),
                address(this)
            );
        }

        // Step 3: TODO: swap

        // Step 4: Repay WETH debt on Aave
        uint256 aaveDebt = _getAaveDebt();
        if (aaveDebt > 0) {
            aavePool.repay(address(weth), aaveDebt, 2, address(this));
        }

        // Step 5: Withdraw USDC from Aave
        aavePool.withdraw(address(usdc), type(uint256).max, address(this));

        // Reset tracking variables
        totalWethBorrowed = 0;
        totalStEthHeld = 0;
        currentIterations = 0;

        emit UnwindLoop(iterations, wethDebt, stEthHeld);
    }

    /// @notice Unwinds only as much of the loop as needed to free up a specific amount of assets
    /// @param assetsNeeded Amount of assets (USDC) needed
    function _unwindLoopAsNeeded(uint256 assetsNeeded) internal {
        uint256 usdcBalance = usdc.balanceOf(address(this));

        if (usdcBalance >= assetsNeeded || currentIterations == 0) return;

        uint256 additionalUsdcNeeded = assetsNeeded - usdcBalance;

        // Calculate how much of the loop to unwind
        uint256 totalPositionValue = _getUsdcValue() + _getStEthValueInUsdc();
        uint256 wethDebtValue = _getWethDebtInUsdc();
        uint256 netPositionValue = totalPositionValue - wethDebtValue;

        // If we can't free up enough funds, unwind everything
        if (netPositionValue < additionalUsdcNeeded) {
            _unwindLoop();
            return;
        }

        // Otherwise, calculate partial unwind ratio
        uint256 unwindRatio = additionalUsdcNeeded * BASIS_POINTS / netPositionValue;

        // First partially repay Morpho debt
        IMorpho.MarketParams memory marketParams = morpho.idToMarketParams(morphoMarketId);
        uint256 morphoDebt = morpho.expectedBorrowAssets(marketParams, address(this));
        if (morphoDebt > 0) {
            uint256 morphoRepayAmount = morphoDebt * unwindRatio / BASIS_POINTS;
            if (morphoRepayAmount > 0) {
                // Ensure we have enough WETH
                uint256 wethBalance = weth.balanceOf(address(this));
                if (wethBalance < morphoRepayAmount) {
                    // Borrow more from Aave temporarily if needed
                    aavePool.borrow(address(weth), morphoRepayAmount - wethBalance, 2, 0, address(this));
                }

                morpho.repay(marketParams, morphoRepayAmount, 0, address(this), "");
            }
        }

        // Partially withdraw stETH from Morpho
        uint256 morphoStEth = morpho.expectedSupplyAssets(marketParams, address(this));
        if (morphoStEth > 0) {
            uint256 stEthToWithdraw = morphoStEth * unwindRatio / BASIS_POINTS;
            if (stEthToWithdraw > 0) {
                morpho.withdraw(marketParams, stEthToWithdraw, 0, address(this), address(this));
            }
        }

        // TODO: swap

        // Partially repay Aave debt
        uint256 aaveDebt = _getAaveDebt();
        if (aaveDebt > 0) {
            uint256 aaveRepayAmount = aaveDebt * unwindRatio / BASIS_POINTS;
            if (aaveRepayAmount > 0) {
                aavePool.repay(address(weth), aaveRepayAmount, 2, address(this));
            }
        }

        // Withdraw needed USDC from Aave
        aavePool.withdraw(address(usdc), additionalUsdcNeeded, address(this));

        // Update tracking variables
        totalWethBorrowed = totalWethBorrowed * (BASIS_POINTS - unwindRatio) / BASIS_POINTS;
        totalStEthHeld = totalStEthHeld * (BASIS_POINTS - unwindRatio) / BASIS_POINTS;
        currentIterations = currentIterations * (BASIS_POINTS - unwindRatio) / BASIS_POINTS;
    }

    /// @notice Returns the USDC value of the vault's position
    /// @dev Calculates the value of USDC supplied to Aave
    /// @return Value in USDC
    function _getUsdcValue() internal view returns (uint256) {
        // Get USDC supplied as collateral on Aave
        (uint256 totalCollateralBase, uint256 totalDebtBase,,,,) = aavePool.getUserAccountData(address(this));

        // Add direct USDC balance held by the vault
        uint256 directUsdcBalance = usdc.balanceOf(address(this));

        return totalCollateralBase + directUsdcBalance;
    }

    /// @notice Returns the value of stETH held in USDC terms
    /// @dev Converts stETH value to USDC using price oracle
    /// @return Value in USDC
    function _getStEthValueInUsdc() internal view returns (uint256) {
        // Get stETH balance from Morpho
        IMorpho.MarketParams memory marketParams = morpho.idToMarketParams(morphoMarketId);
        uint256 suppliedStEth = morpho.expectedSupplyAssets(marketParams, address(this));

        // Add direct stETH balance held by the vault
        uint256 directStEthBalance = stEth.balanceOf(address(this));
        uint256 totalStEth = suppliedStEth + directStEthBalance;

        // Get the price of stETH in terms of USDC
        // This would typically come from a price oracle
        // For simplicity, we can use Aave's price oracle
        uint256 stEthPriceInEth = getStEthPriceInEth(); // Price of stETH in ETH
        uint256 ethPriceInUsdc = getEthPriceInUsdc(); // Price of ETH in USDC

        return (totalStEth * stEthPriceInEth * ethPriceInUsdc) / (1e18 * 1e18);
    }

    /// @notice Returns the value of WETH debt in USDC terms
    /// @dev Converts WETH debt to USDC using price oracle
    /// @return Value in USDC
    function _getWethDebtInUsdc() internal view returns (uint256) {
        // Get WETH debt from Aave
        uint256 aaveDebt = _getAaveDebt();

        // Get WETH debt from Morpho
        IMorpho.MarketParams memory marketParams = morpho.idToMarketParams(morphoMarketId);
        uint256 morphoDebt = morpho.expectedBorrowAssets(marketParams, address(this));

        uint256 totalWethDebt = aaveDebt + morphoDebt;

        // Get the price of ETH in terms of USDC
        uint256 ethPriceInUsdc = getEthPriceInUsdc();

        return (totalWethDebt * ethPriceInUsdc) / 1e18;
    }

    /// @notice Calculates the borrow capacity on Aave
    /// @dev Uses Aave's user account data to determine how much can be borrowed
    /// @return Borrow capacity in WETH
    function _calculateBorrowCapacityAave() internal view returns (uint256) {
        (,, uint256 availableBorrowsBase,,,) = aavePool.getUserAccountData(address(this));

        // Convert available borrows from USD to WETH using price oracle
        uint256 ethPriceInUsdc = getEthPriceInUsdc();

        return (availableBorrowsBase * 1e18) / ethPriceInUsdc;
    }

    /// @notice Calculates the borrow capacity on Morpho
    /// @param marketParams The Morpho market parameters
    /// @return Borrow capacity in WETH
    function _calculateBorrowCapacityMorpho(IMorpho.MarketParams memory marketParams) internal view returns (uint256) {
        // Get stETH supplied as collateral to Morpho
        uint256 suppliedStEth = morpho.expectedSupplyAssets(marketParams, address(this));

        // Apply LTV (Loan-to-Value) to determine borrow capacity
        // For simplicity, assuming a 75% LTV for stETH
        uint256 ltv = 75; // 75% LTV

        // Convert stETH to WETH equivalent using the stETH/ETH exchange rate
        uint256 stEthPriceInEth = getStEthPriceInEth();

        return (suppliedStEth * stEthPriceInEth * ltv) / (1e18 * 100);
    }
    /// @notice Gets the current health factor on Aave
    /// @dev Queries Aave for the health factor of this contract's position
    /// @return Health factor (scaled by 10000)

    function _getCurrentHealthFactorAave() internal view returns (uint256) {
        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));

        // Aave returns health factor in RAY (1e27), we convert to our BASIS_POINTS scale (1e4)
        return (healthFactor * BASIS_POINTS) / 1e27;
    }

    /// @notice Gets the current debt on Aave
    /// @dev Queries Aave for the debt of this contract
    /// @return Debt amount in WETH
    function _getAaveDebt() internal view returns (uint256) {
        (, uint256 totalDebtBase,,,,) = aavePool.getUserAccountData(address(this));

        // Convert debt from USD to WETH using price oracle
        uint256 ethPriceInUsdc = getEthPriceInUsdc();

        return (totalDebtBase * 1e18) / ethPriceInUsdc;
    }

    function getStEthPriceInEth() internal view returns (uint256) { }

    /// @notice Helper function to get ETH price in USDC
    /// @dev Uses a price oracle to get the current exchange rate
    /// @return ETH price in USDC (1e18 precision)
    function getEthPriceInUsdc() internal view returns (uint256) { }

    /// @notice Harvests any rewards from Lido staking
    /// @dev Claims and processes stETH rewards
    function _harvestLidoRewards() internal {
        // Empty implementation
    }
}
