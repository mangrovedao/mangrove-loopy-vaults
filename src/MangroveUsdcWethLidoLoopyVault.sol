// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import { IAavePool } from "./interfaces/IAavePool.sol";
import { IERC20, SafeERC20 } from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin-contracts/utils/math/Math.sol";

import { IMorpho, Id, MarketParams } from "morpho-org-morpho-blue/src/interfaces/IMorpho.sol";
import { MarketParamsLib } from "morpho-org-morpho-blue/src/libraries/MarketParamsLib.sol";
import { MorphoBalancesLib } from "morpho-org-morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import { MorphoLib } from "morpho-org-morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {
    BaseMangroveLoopyVault, IERC4626, PendingAddress, PendingLib, UtilsLib
} from "src/base/BaseMangroveLoopyVault.sol";

import { IAggregatorV3Interface } from "src/interfaces/IAggregatorV3Interface.sol";
import { IMangroveGhostbook } from "src/interfaces/IMangroveGhostbook.sol";
import { ISwapModule } from "src/interfaces/ISwapModule.sol";

/// @title MangroveUsdcWethLidoLoopyVault
/// @author Mangrove
/// @notice A looping vault that leverages USDC to borrow WETH, stakes in Lido, and uses stETH on Morpho to borrow more
/// WETH
/// @dev Inherits from BaseMangroveLoopyVault and implements looping strategy
contract MangroveUsdcWethLidoLoopyVault is BaseMangroveLoopyVault {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using MorphoLib for IMorpho;
    using UtilsLib for uint256;
    using MorphoBalancesLib for IMorpho;
    using MarketParamsLib for MarketParams;
    using PendingLib for PendingAddress;

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

    /// @notice Emitted when a new target LTV for Morpho is set
    /// @param newMorphoLtv The new target LTV for Morpho borrowing
    event SetMorphoLtv(uint256 newMorphoLtv);

    /// @notice Emitted when a new swap module is submitted (pending)
    /// @param newSwapModule Address of the proposed new swap module
    event SubmitSwapModule(address indexed newSwapModule);

    /// @notice Emitted when the swap module is updated
    /// @param sender Address that triggered the swap module update
    /// @param newSwapModule Address of the new swap module
    event SetSwapModule(address indexed sender, address indexed newSwapModule);

    /// @notice Emitted when price oracle addresses are updated
    /// @param ethUsdOracle New ETH/USD oracle address
    /// @param stEthEthOracle New stETH/ETH oracle address
    event SetPriceOracles(address indexed ethUsdOracle, address indexed stEthEthOracle);

    /// @notice Emitted when the price staleness tolerance is updated
    /// @param newStaleness New staleness tolerance in seconds
    event SetPriceStaleness(uint256 newStaleness);

    // In the errors section, add:
    /// @notice Thrown when trying to set an LTV that's too high
    error MorphoLtvTooHigh();

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

    /// @notice Thrown when a price feed returns stale data
    error StalePrice();

    /// @notice Thrown when a price feed returns a negative price
    error NegativePrice();

    /* STORAGE */

    /// @notice Address of the USDC token
    IERC20 public immutable usdc;

    /// @notice Address of the WETH token
    IERC20 public immutable weth;

    /// @notice Address of the stETH token from Lido
    IERC20 public immutable stEth;

    /// @notice Aave lending pool contract
    IAavePool public immutable aavePool;

    /// @notice Morpho protocol contract
    IMorpho public immutable morpho;

    ISwapModule public swapper;

    IMangroveGhostbook public ghostbook;

    /// @notice Morpho market ID for stETH-WETH market
    Id public immutable morphoMarketId;

    MarketParams private _morphoMarketParams;

    /// @notice Pending swap module address with its timelock information
    PendingAddress public pendingSwapModule;

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

    /// @notice Maximum allowed LTV for Morpho borrowing
    uint256 public constant MAX_MORPHO_LTV = 80; // 80%

    /// @notice Maximum price feed staleness allowed (upgradeable)
    uint256 public maxPriceStaleness;

    /// @notice Current number of loop iterations active
    uint256 public currentIterations;

    /// @notice Total WETH borrowed across all iterations
    uint256 public totalWethBorrowed;

    /// @notice Total stETH held from all iterations
    uint256 public totalStEthHeld;

    uint256 public morphoLtv;

    /// @notice Chainlink price feed for ETH/USD
    IAggregatorV3Interface public ethUsdPriceFeed;

    /// @notice Chainlink price feed for stETH/ETH
    IAggregatorV3Interface public stEthEthPriceFeed;

    /// @notice Constructs the MangroveUsdcWethLidoLoopyVault
    /// @param owner Address of the vault owner
    /// @param initialTimelock Initial timelock duration
    /// @param usdc Address of the USDC token
    /// @param weth Address of the WETH token
    /// @param lido Address of the Lido staking contract
    /// @param stEth Address of the stETH token
    /// @param aavePool Address of the Aave lending pool
    /// @param morpho Address of the Morpho protocol
    /// @param morphoMarketParams Morpho market params for stETH-WETH market
    /// @param maxIterations Maximum number of loop iterations allowed
    /// @param targetLeverage Target leverage multiplier (in basis points)
    /// @param name Name of the vault token
    /// @param symbol Symbol of the vault token
    struct VaultParams {
        address owner;
        uint256 initialTimelock;
        address usdc;
        address weth;
        address stEth;
        address aavePool;
        address morpho;
        MarketParams morphoMarketParams;
        uint256 maxIterations;
        uint256 targetLeverage;
        string name;
        string symbol;
        address swapper;
        IMangroveGhostbook ghostbook;
        uint256 morphoLtv;
        address ethUsdPriceFeed;
        address stEthEthPriceFeed;
        uint256 maxPriceStaleness;
        address curator;
        address guardian;
        address feeRecipient;
        address allocator;
        uint96 fee;
    }

    constructor(VaultParams memory params)
        BaseMangroveLoopyVault(params.owner, params.initialTimelock, params.usdc, params.name, params.symbol)
    {
        require(params.maxIterations > 0, "Zero max iterations");
        require(params.targetLeverage > 0, "Zero target leverage");
        require(params.targetLeverage <= MAX_LEVERAGE, "Target leverage too high");
        require(params.morphoLtv > 0, "Zero Morpho LTV");
        require(params.morphoLtv <= MAX_MORPHO_LTV, "Morpho LTV too high");
        require(params.ethUsdPriceFeed != address(0), "Zero ETH/USD oracle");
        require(params.stEthEthPriceFeed != address(0), "Zero stETH/ETH oracle");
        require(params.maxPriceStaleness > 0, "Zero max price staleness");

        usdc = IERC20(params.usdc);
        weth = IERC20(params.weth);
        stEth = IERC20(params.stEth);
        aavePool = IAavePool(params.aavePool);
        morpho = IMorpho(params.morpho);
        _morphoMarketParams = params.morphoMarketParams;
        morphoLtv = params.morphoLtv;
        morphoMarketId = params.morphoMarketParams.id();
        maxIterations = params.maxIterations;
        targetLeverage = params.targetLeverage;
        swapper = ISwapModule(params.swapper);
        ghostbook = params.ghostbook;

        ethUsdPriceFeed = IAggregatorV3Interface(params.ethUsdPriceFeed);
        stEthEthPriceFeed = IAggregatorV3Interface(params.stEthEthPriceFeed);
        maxPriceStaleness = params.maxPriceStaleness;

        curator = params.curator;
        guardian = params.guardian;
        feeRecipient = params.feeRecipient;
        isAllocator[params.allocator] = true;
        fee = params.fee;

        // Verify that the market exists and has the correct tokens
        MarketParams memory marketParams = morpho.idToMarketParams(morphoMarketId);
        require(marketParams.loanToken == params.weth, "Invalid loan token in Morpho market");
        require(marketParams.collateralToken == params.stEth, "Invalid collateral token in Morpho market");

        // Approve tokens for protocol interactions
        usdc.forceApprove(params.aavePool, type(uint256).max);
        weth.forceApprove(params.swapper, type(uint256).max);
        weth.forceApprove(params.aavePool, type(uint256).max);
        stEth.forceApprove(params.morpho, type(uint256).max);
        stEth.forceApprove(params.swapper, type(uint256).max);
    }

    // Add function to set the Morpho LTV:
    /// @notice Sets the target LTV for Morpho borrowing
    /// @dev Only callable by the owner
    /// @param _morphoLtv New target LTV for Morpho (in basis points)
    function setMorphoLtv(uint256 _morphoLtv) external onlyOwner {
        require(_morphoLtv > 0, "Zero Morpho LTV");
        if (_morphoLtv > MAX_MORPHO_LTV) revert MorphoLtvTooHigh();
        morphoLtv = _morphoLtv;
        emit SetMorphoLtv(_morphoLtv);
    }

    // Add function to submit a new swap module (with timelock):
    /// @notice Submits a new swap module for approval
    /// @dev Only callable by the owner. Requires timelock approval.
    /// @param _newSwapModule Address of the proposed new swap module
    function submitSwapModule(address _newSwapModule) external onlyOwner {
        if (_newSwapModule == address(0)) revert ZeroAddress();
        if (_newSwapModule == address(swapper)) revert AlreadySet();
        if (pendingSwapModule.validAt != 0) revert AlreadyPending();

        pendingSwapModule.update(_newSwapModule, timelock);

        emit SubmitSwapModule(_newSwapModule);
    }

    // Add function to accept a pending swap module:
    /// @notice Accepts a pending swap module after timelock has expired
    /// @dev Can be called by anyone after timelock period
    function acceptSwapModule() external afterTimelock(pendingSwapModule.validAt) {
        address newSwapModule = pendingSwapModule.value;

        // Approve the new swap module for stETH
        stEth.forceApprove(address(swapper), 0); // Remove approval from old swapper
        stEth.forceApprove(newSwapModule, type(uint256).max); // Approve new swapper

        swapper = ISwapModule(newSwapModule);

        emit SetSwapModule(_msgSender(), newSwapModule);

        delete pendingSwapModule;
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

    /// @notice Sets the maximum price staleness tolerance
    /// @dev Only callable by the owner
    /// @param _maxPriceStaleness New maximum price staleness in seconds
    function setMaxPriceStaleness(uint256 _maxPriceStaleness) external onlyOwner {
        require(_maxPriceStaleness > 0, "Zero max price staleness");
        maxPriceStaleness = _maxPriceStaleness;
        emit SetPriceStaleness(_maxPriceStaleness);
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

    /// @inheritdoc IERC4626
    function totalAssets() public view override returns (uint256) {
        // Direct USDC balance held by the vault
        uint256 directUsdcBalance = usdc.balanceOf(address(this));

        // USDC supplied as collateral on Aave
        (uint256 usdcCollateral,,,,,) = aavePool.getUserAccountData(address(this));

        // Value of stETH (minus the WETH debt) - this represents our earned yield
        uint256 netPositionValue = _getStEthValueInUsdc() - _getWethDebtInUsdc();

        return directUsdcBalance + usdcCollateral + netPositionValue;
    }

    /// @inheritdoc IERC4626
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

    /// @inheritdoc IERC4626
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        uint256 newTotalAssets = _accrueFee();

        // Do not call expensive `maxWithdraw` and optimistically withdraw assets.
        shares = _convertToSharesWithTotals(assets, totalSupply(), newTotalAssets, Math.Rounding.Ceil);

        // `newTotalAssets - assets` may be a little off from `totalAssets()`.
        _updateLastTotalAssets(newTotalAssets.zeroFloorSub(assets));

        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        uint256 newTotalAssets = _accrueFee();

        // Do not call expensive `maxRedeem` and optimistically redeem shares.
        assets = _convertToAssetsWithTotals(shares, totalSupply(), newTotalAssets, Math.Rounding.Floor);

        // `newTotalAssets - assets` may be a little off from `totalAssets()`.
        _updateLastTotalAssets(newTotalAssets.zeroFloorSub(assets));

        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    )
        internal
        override
    {
        uint256 directBalance = usdc.balanceOf(address(this));
        if (assets > directBalance) {
            IMangroveGhostbook.ModuleData memory data;
            assets = _unwindLoopAsNeeded(
                assets - directBalance, 0, IMangroveGhostbook.Tick.wrap(0), data
            );
        }
        super._withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    /// @notice Rebalances the loop strategy by adjusting leverage incrementally
    /// @dev Adds or removes positions to achieve target leverage without fully unwinding
    /// @param tickSpacing The tick spacing for any swaps needed during rebalancing
    /// @param maxTick The maximum tick for the swap
    /// @param moduleData Additional data for the swap module
    function rebalance(
        uint256 tickSpacing,
        IMangroveGhostbook.Tick maxTick,
        IMangroveGhostbook.ModuleData memory moduleData
    )
        external
        onlyAllocatorRole
    {
        uint256 newTotalAssets = _accrueFee();
        lastTotalAssets = newTotalAssets;

        uint256 currentLeverage = currentLeverageFactor();
        if (currentLeverage == targetLeverage) return;

        uint256 leverageDelta =
            currentLeverage < targetLeverage ? targetLeverage - currentLeverage : currentLeverage - targetLeverage;

        if (leverageDelta < 5) return; // 0.05% adjustment threshold

        if (currentLeverage < targetLeverage) {
            _increaseDebt(leverageDelta, tickSpacing, maxTick, moduleData);
        } else {
            _unwindLoopAsNeeded(leverageDelta, tickSpacing, maxTick, moduleData);
        }

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

        // Borrow WETH to initiate loop
        IMangroveGhostbook.ModuleData memory data;
        _increaseDebt(
            usdcBalance,
            0,
            IMangroveGhostbook.Tick.wrap(0),
            data
        );
    }

    function _increaseDebt(
        uint256 usdcAmount,
        uint256 tickSpacing,
        IMangroveGhostbook.Tick maxTick,
        IMangroveGhostbook.ModuleData memory moduleData
    )
        internal
    {
        uint256 initialBorrowCapacity = _calculateBorrowCapacityAave();
        uint256 targetBorrowAmount = usdcAmount * targetLeverage / BASIS_POINTS;
        uint256 borrowedSoFar = 0;

        // Initial borrow from Aave
        uint256 initialBorrow = Math.min(initialBorrowCapacity, targetBorrowAmount);
        if (initialBorrow > 0) {
            aavePool.borrow(address(weth), initialBorrow, 2, 0, address(this));
            borrowedSoFar += initialBorrow;
            totalWethBorrowed += initialBorrow;
        }

        // Swap WETH to stETH
        uint256 stEthReceived;
        if (tickSpacing == 0) {
            stEthReceived = _fastSwap(false, initialBorrow);
        } else {
            stEthReceived = _optimalSwap(false, initialBorrow, tickSpacing, maxTick, moduleData);
        }
        totalStEthHeld += stEthReceived;

        // Start looping process
        for (uint256 i = 0; i < maxIterations && borrowedSoFar < targetBorrowAmount; i++) {
            // Supply stETH to Morpho as collateral
            morpho.supplyCollateral(_morphoMarketParams, stEthReceived, address(this), "");

            // Calculate borrow amount from Morpho
            uint256 morphoBorrowAmount =
                Math.min(_calculateBorrowCapacityMorpho(_morphoMarketParams), targetBorrowAmount - borrowedSoFar);

            if (morphoBorrowAmount == 0) break;

            // Borrow WETH from Morpho
            (uint256 borrowedWeth,) = morpho.borrow(
                _morphoMarketParams,
                morphoBorrowAmount,
                0, // max shares
                address(this),
                address(this)
            );

            borrowedSoFar += borrowedWeth;
            totalWethBorrowed += borrowedWeth;

            // Swap new WETH to stETH for next iteration
            if (tickSpacing == 0) {
                stEthReceived = _fastSwap(false, initialBorrow);
            } else {
                stEthReceived = _optimalSwap(false, initialBorrow, tickSpacing, maxTick, moduleData);
            }
            totalStEthHeld += stEthReceived;

            currentIterations++;

            emit LoopIteration(i + 1, borrowedWeth, stEthReceived);

            // Check health factor after each iteration
            uint256 healthFactor = _getCurrentHealthFactorAave();
            if (healthFactor < MIN_HEALTH_FACTOR * 100) {
                break;
            }
        }
    }

    /// @notice Unwinds the loop position completely
    /// @dev Repays all WETH debt and redeems all stETH
    function _unwindLoop() internal returns (uint256 balance) {
        IMangroveGhostbook.ModuleData memory data;
        return
            _unwindLoopAsNeeded(totalAssets(), 0, IMangroveGhostbook.Tick.wrap(0), data);
    }

    /// @notice Unwinds only as much of the loop as needed to free up a specific amount of assets
    /// @param assetsNeeded Amount of assets (USDC) needed
    function _unwindLoopAsNeeded(
        uint256 assetsNeeded,
        uint256 tickSpacing,
        IMangroveGhostbook.Tick maxTick,
        IMangroveGhostbook.ModuleData memory moduleData
    )
        internal
        returns (uint256)
    {
        uint256 directBalance = usdc.balanceOf(address(this));
        if (directBalance >= assetsNeeded || currentIterations == 0) return assetsNeeded;

        uint256 additionalUsdcNeeded = assetsNeeded - directBalance;

        // Calculate how much of the loop to unwind
        uint256 netPositionValue = totalAssets();

        // If we can't free up enough funds, unwind everything
        if (netPositionValue < additionalUsdcNeeded) {
            return _unwindLoop();
        }

        // Otherwise, calculate partial unwind ratio
        uint256 unwindRatio = additionalUsdcNeeded * BASIS_POINTS / netPositionValue;

        // First partially repay Morpho debt
        MarketParams memory marketParams = morpho.idToMarketParams(morphoMarketId);
        uint256 morphoDebt = morpho.expectedBorrowAssets(_morphoMarketParams, address(this));
        if (morphoDebt > 0) {
            uint256 morphoRepayAmount = morphoDebt * unwindRatio / BASIS_POINTS;
            if (morphoRepayAmount > 0) {
                // Ensure we have enough WETH
                uint256 wethBalance = weth.balanceOf(address(this));
                if (wethBalance < morphoRepayAmount) {
                    // Swap stEth to weth
                    uint256 stEthToSwap = 0;
                    uint256 morphoRepayAmountBefore = morphoRepayAmount;
                    if (tickSpacing == 0) {
                        morphoRepayAmount -= _fastSwap(true, stEthToSwap);
                    } else {
                        morphoRepayAmount -= _optimalSwap(true, stEthToSwap, tickSpacing, maxTick, moduleData);
                    }
                    // Reduce all requested values by the % of losses of he swap
                    assetsNeeded = assetsNeeded * morphoRepayAmountBefore / morphoRepayAmount;
                    additionalUsdcNeeded = additionalUsdcNeeded * morphoRepayAmountBefore / morphoRepayAmount;
                    unwindRatio = additionalUsdcNeeded * morphoRepayAmountBefore / morphoRepayAmount;
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

        return assetsNeeded;
    }

    function _fastSwap(bool stEthToWeth, uint256 amountIn) internal returns (uint256 losses) {
        address tokenIn = stEthToWeth ? address(stEth) : address(weth);
        address tokenOut = stEthToWeth ? address(weth) : address(stEth);
        uint256 amountOut = swapper.swap(tokenIn, tokenOut, amountIn);
        uint256 expectedOut;
        if (stEthToWeth) {
            expectedOut = amountIn * getStEthPriceInEth() / 1e18;
        } else {
            expectedOut = amountIn * 1e18 / getStEthPriceInEth();
        }
        losses = expectedOut > amountOut ? expectedOut - amountOut : 0;
        return losses;
    }

    function _optimalSwap(
        bool stEthToWeth,
        uint256 amountIn,
        uint256 tickSpacing,
        IMangroveGhostbook.Tick maxTick,
        IMangroveGhostbook.ModuleData memory moduleData
    )
        internal
        returns (uint256 losses)
    {
        IMangroveGhostbook.OLKey memory key = IMangroveGhostbook.OLKey({
            outbound_tkn: stEthToWeth ? address(weth) : address(stEth),
            inbound_tkn: stEthToWeth ? address(stEth) : address(weth),
            tickSpacing: tickSpacing
        });
        (uint256 takerGot, uint256 takerGave,,) = ghostbook.marketOrderByTick(key, maxTick, amountIn, moduleData);
        if (takerGave < amountIn) revert();
        uint256 expectedOut =
            stEthToWeth ? amountIn * getStEthPriceInEth() / 1e18 : amountIn * 1e18 / getStEthPriceInEth();
        losses = expectedOut > takerGot ? expectedOut - takerGot : 0;
        return losses;
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
        MarketParams memory marketParams = morpho.idToMarketParams(morphoMarketId);
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
        MarketParams memory marketParams = morpho.idToMarketParams(morphoMarketId);
        uint256 morphoDebt = morpho.expectedBorrowAssets(marketParams, address(this));

        uint256 totalWethDebt = aaveDebt + morphoDebt;

        // Get the price of ETH in terms of USDC
        uint256 ethPriceInUsdc = getEthPriceInUsdc();

        return (totalWethDebt * ethPriceInUsdc) / 1e18;
    }

    /// @notice Calculates the borrow capacity on Morpho
    /// @param marketParams The Morpho market parameters
    /// @return Borrow capacity in WETH
    function _calculateBorrowCapacityMorpho(MarketParams memory marketParams) internal view returns (uint256) {
        // Get stETH supplied as collateral to Morpho
        uint256 suppliedStEth = morpho.expectedSupplyAssets(marketParams, address(this));

        // Apply the configurable LTV to determine borrow capacity
        // Convert stETH to WETH equivalent using the stETH/ETH exchange rate
        uint256 stEthPriceInEth = getStEthPriceInEth();

        return (suppliedStEth * stEthPriceInEth * morphoLtv) / (1e18 * 100);
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

    /// @notice Gets the current ETH price in USD from Chainlink Oracle
    /// @dev Returns price with 8 decimals precision, scaled to 18 decimals
    /// @return ETH price in USD (1e18 precision)
    function getEthPriceInUsdc() public view returns (uint256) {
        // Get the latest price from Chainlink
        (
            uint80 roundId,
            int256 price,
            /* uint startedAt */
            ,
            uint256 updatedAt,
            /* uint80 answeredInRound */
        ) = ethUsdPriceFeed.latestRoundData();

        // Check if the price is stale
        if (block.timestamp - updatedAt > maxPriceStaleness) revert StalePrice();

        // Check if price is positive
        if (price <= 0) revert NegativePrice();

        // ETH/USD price feed typically has 8 decimals, convert to 18 decimals
        // USDC has 6 decimals, but for internal calculations we use 18 decimals
        uint256 ethPriceInUsd = uint256(price) * 1e10;

        return ethPriceInUsd;
    }

    /// @notice Gets the current stETH price in ETH from Chainlink Oracle
    /// @dev Returns ratio with 18 decimals precision
    /// @return stETH price in ETH (1e18 precision)
    function getStEthPriceInEth() public view returns (uint256) {
        // Get the latest price from Chainlink
        (
            uint80 roundId,
            int256 price,
            /* uint startedAt */
            ,
            uint256 updatedAt,
            /* uint80 answeredInRound */
        ) = stEthEthPriceFeed.latestRoundData();

        // Check if the price is stale
        if (block.timestamp - updatedAt > maxPriceStaleness) revert StalePrice();

        // Check if price is positive
        if (price <= 0) revert NegativePrice();

        // stETH/ETH price feed typically has 18 decimals
        uint256 stEthPriceInEth = uint256(price);

        return stEthPriceInEth;
    }
}
