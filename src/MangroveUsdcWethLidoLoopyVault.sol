
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import { IERC20, SafeERC20 } from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin-contracts/utils/math/Math.sol";
import { ILido } from "./interfaces/ILido.sol";
import { IAavePool } from "./interfaces/IAavePool.sol";
import { BaseMangroveLoopyVault } from "./BaseMangroveLoopyVault.sol";

/// @title MangroveUsdcWethLidoLoopyVault
/// @author Mangrove
/// @notice A looping vault that leverages USDC to borrow WETH, stakes in Lido, and loops
/// @dev Inherits from BaseMangroveLoopyVault and implements looping strategy with Lido
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

    /// @notice Maximum number of loop iterations allowed
    uint256 public maxIterations;

    /// @notice Target leverage multiplier (in basis points, e.g., 300 = 3x)
    uint256 public targetLeverage;

    /// @notice Minimum health factor to maintain (in basis points, e.g., 120 = 1.2)
    uint256 public constant MIN_HEALTH_FACTOR = 120;

    /// @notice Maximum leverage factor allowed (in basis points, e.g., 500 = 5x)
    uint256 public constant MAX_LEVERAGE = 500;

    /// @notice Basis points denominator (10000 = 100%)
    uint256 public constant BASIS_POINTS = 10000;

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
        maxIterations = _maxIterations;
        targetLeverage = _targetLeverage;
        usdc.safeApprove(address(aavePool), type(uint256).max);
        weth.safeApprove(address(lido), type(uint256).max);
        steth.safeApprove(address(morpho), type(uint256).max);
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
        
        // Harvest any staking rewards
        _harvestLidoRewards();
        
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
        
        // Calculate initial borrow capacity
        uint256 initialBorrowCapacity = _calculateBorrowCapacity();
        uint256 remainingBorrowCapacity = initialBorrowCapacity;
        
        // Calculate how much to borrow based on target leverage
        uint256 targetBorrowAmount = usdcBalance * targetLeverage / BASIS_POINTS;
        uint256 borrowedSoFar = 0;
        
        // Start looping process
        for (uint256 i = 0; i < maxIterations && borrowedSoFar < targetBorrowAmount; i++) {
            // Calculate how much WETH to borrow in this iteration
            uint256 iterationBorrow = Math.min(
                remainingBorrowCapacity,
                targetBorrowAmount - borrowedSoFar
            );
            
            if (iterationBorrow == 0) break;
            
            // Borrow WETH from Aave
            aavePool.borrow(address(weth), iterationBorrow, 2, 0, address(this));
            
            // Stake WETH in Lido to get stETH
            uint256 stEthBefore = stEth.balanceOf(address(this));
            lido.submit(iterationBorrow);
            uint256 stEthReceived = stEth.balanceOf(address(this)) - stEthBefore;
            
            // Supply stETH to Aave as additional collateral
            aavePool.supply(address(stEth), stEthReceived, address(this), 0);
            
            // Update tracking variables
            borrowedSoFar += iterationBorrow;
            totalWethBorrowed += iterationBorrow;
            totalStEthHeld += stEthReceived;
            currentIterations++;
            
            // Update remaining borrow capacity
            remainingBorrowCapacity = _calculateBorrowCapacity();
            
            emit LoopIteration(i + 1, iterationBorrow, stEthReceived);
            
            // Check health factor after each iteration
            uint256 healthFactor = _getCurrentHealthFactor();
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
        
        // Withdraw stETH from Aave
        aavePool.withdraw(address(stEth), type(uint256).max, address(this));
        
        // Convert stETH back to WETH (in a real implementation, this might use a DEX or unwrapping mechanism)
        // For simplicity, we're assuming stETH can be directly used to repay WETH
        
        // Repay WETH debt
        aavePool.repay(address(weth), wethDebt, 2, address(this));
        
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
            
            // Withdraw USDC from Aave
            aavePool.withdraw(address(usdc), type(uint256).max, address(this));
            return;
        }
        
        // Otherwise, calculate partial unwind
        uint256 unwindRatio = additionalUsdcNeeded * BASIS_POINTS / netPositionValue;
        
        // Unwinding stETH proportionally
        uint256 stEthToWithdraw = totalStEthHeld * unwindRatio / BASIS_POINTS;
        if (stEthToWithdraw > 0) {
            aavePool.withdraw(address(stEth), stEthToWithdraw, address(this));
        }
        
        // Calculate WETH debt to repay proportionally
        uint256 wethToRepay = totalWethBorrowed * unwindRatio / BASIS_POINTS;
        if (wethToRepay > 0) {
            aavePool.repay(address(weth), wethToRepay, 2, address(this));
            
            // Update tracking variables
            totalWethBorrowed -= wethToRepay;
            totalStEthHeld -= stEthToWithdraw;
            currentIterations = currentIterations * (BASIS_POINTS - unwindRatio) / BASIS_POINTS;
        }
        
        // Withdraw needed USDC from Aave
        aavePool.withdraw(address(usdc), additionalUsdcNeeded, address(this));
    }

    /// @notice Harvests any staking rewards from Lido
    /// @dev Internal function to collect and reinvest staking rewards
    function _harvestLidoRewards() internal {
      
    }

    /// @notice Calculates the current borrow capacity
    /// @return Maximum amount of WETH that can be borrowed
    function _calculateBorrowCapacity() internal view returns (uint256) {
        // This would call Aave to determine maximum borrow capacity
        // For simplicity, returning a placeholder calculation
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(stEth);
        
        // Get user account data from Aave
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            ,  // unused
            uint256 currentLtv,
            ,  // unused
            uint256 healthFactor
        ) = aavePool.getUserAccountData(address(this));
        
        // If health factor is below safe threshold, don't allow more borrowing
        if (healthFactor < MIN_HEALTH_FACTOR * 100) return 0;
        
        // Calculate maximum additional borrow amount
        uint256 maxBorrow = totalCollateralBase * currentLtv / 10000 - totalDebtBase;
        return maxBorrow > 0 ? maxBorrow : 0;
    }

    /// @notice Gets the current health factor from Aave
    /// @return Current health factor (scaled by 10000)
    function _getCurrentHealthFactor() internal view returns (uint256) {
        (, , , , , uint256 healthFactor) = aavePool.getUserAccountData(address(this));
        return healthFactor;
    }

    /// @notice Gets the value of USDC held by the vault (including Aave deposits)
    /// @return USDC value
    function _getUsdcValue() internal view returns (uint256) {
      
    }

    /// @notice Gets the value of stETH held by the vault in USDC terms
    /// @return stETH value in USDC
    function _getStEthValueInUsdc() internal view returns (uint256) {

    }

    /// @notice Gets the value of WETH debt in USDC terms
    /// @return WETH debt value in USDC
    function _getWethDebtInUsdc() internal view returns (uint256) {
        
    }

    /// @notice Gets the exchange rate from stETH to USDC
    /// @return Exchange rate (stETH to USDC)
    function _getStEthToUsdcRate() internal view returns (uint256) {
      
    }

    /// @notice Gets the exchange rate from WETH to USDC
    /// @return Exchange rate (WETH to USDC)
    function _getWethToUsdcRate() internal view returns (uint256) {
       
    }
}