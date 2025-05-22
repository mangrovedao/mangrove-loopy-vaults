// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import { IAaveOracle } from "./interfaces/IAaveOracle.sol";
import { IAavePool } from "./interfaces/IAavePool.sol";
import { IERC20, SafeERC20 } from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin-contracts/utils/math/Math.sol";

import { IMorpho, Id, MarketParams } from "morpho-org-morpho-blue/src/interfaces/IMorpho.sol";
import { IMorphoFlashLoanCallback } from "morpho-org-morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import { MarketParamsLib } from "morpho-org-morpho-blue/src/libraries/MarketParamsLib.sol";
import { MorphoBalancesLib } from "morpho-org-morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import { MorphoLib } from "morpho-org-morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {
    BaseMangroveLoopyVault,
    ERC4626,
    IERC4626,
    PendingAddress,
    PendingLib,
    UtilsLib
} from "src/base/BaseMangroveLoopyVault.sol";
import { DataTypes } from "src/libraries/AaveDataTypes.sol";

import { IAggregatorV3Interface } from "src/interfaces/IAggregatorV3Interface.sol";
import { IMangroveGhostbook } from "src/interfaces/IMangroveGhostbook.sol";
import { ISwapModule } from "src/interfaces/ISwapModule.sol";

/// @title MangroveUsdcWethLidoLoopyVault
/// @author Mangrove
/// @notice A looping vault that leverages USDC to borrow WETH, stakes in Lido, and uses stETH on Morpho to borrow more
/// WETH
/// @dev Inherits from BaseMangroveLoopyVault and implements looping strategy
contract MangroveUsdcWethLidoLoopyVault is BaseMangroveLoopyVault, IMorphoFlashLoanCallback {
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

    /// @notice Emitted when a new target LTV for Aave is set
    /// @param newAaveLtv The new target LTV for Aave borrowing
    event SetAaveLtv(uint256 newAaveLtv);

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

    /// @notice Emitted when the vault is rebalanced
    /// @param newLeverageFactor The new leverage factor after rebalancing
    /// @param totalAssets The total assets in the vault after rebalancing
    event Rebalanced(uint256 newLeverageFactor, uint256 totalAssets);

    /// @notice Emitted when auto-execute on deposit is toggled
    /// @param enabled Whether auto-execute is now enabled
    event SetAutoExecuteOnDeposit(bool enabled);

    // Errors
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

    /// @notice Thrown when trying to set an Aave LTV that's too high
    error AaveLtvTooHigh();

    /// @notice Thrown when trying to swap an amount that's too small
    error SwapNotFullyConsumed();

    /* STORAGE */

    /// @notice Flag to enable/disable automatic looping on deposits
    bool public autoExecuteOnDeposit;

    /// @notice Address of the USDC token
    IERC20 public immutable usdc;

    /// @notice Address of the WETH token
    IERC20 public immutable weth;

    /// @notice Address of the stETH token from Lido
    IERC20 public immutable stEth;

    /// @notice Aave lending pool contract
    IAavePool public immutable aavePool;

    /// @notice Aaave oracle contract
    IAaveOracle public immutable oracle;

    /// @notice Morpho protocol contract
    IMorpho public immutable morpho;

    /// @notice Swapper module for token exchanges
    ISwapModule public swapper;

    /// @notice Ghostbook contract for Mangrove integration
    IMangroveGhostbook public ghostbook;

    /// @notice Precision factor for Aave oracle price feeds
    uint256 constant AAVE_ORACLE_PRECISION = 1e8;

    /// @notice Morpho market ID for stETH-WETH market
    Id public immutable morphoBorrowId;

    /// @notice Morpho market parameters for the stETH-WETH market
    MarketParams private _morphoBorrowParams;

    /// @notice Pending swap module address with its timelock information
    PendingAddress public pendingSwapModule;

    /// @notice Maximum number of loop iterations allowed
    uint256 public maxIterations;

    /// @notice Target leverage multiplier (in basis points, e.g., 300 = 3x)
    uint256 public targetLeverage;

    /// @notice Minimum health factor to maintain (in basis points, e.g., 120 = 1.2)
    uint256 public constant MIN_HEALTH_FACTOR = 120;

    /// @notice Maximum leverage factor allowed (in basis points, e.g., 20000 = 2x)
    uint256 public constant MAX_LEVERAGE = 50_000;

    /// @notice The basis points denominator (10000 = 100%)
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Maximum allowed LTV for Morpho borrowing
    uint256 public constant MAX_MORPHO_LTV = 9000; // 90%

    /// @notice Maximum allowed LTV for Aave borrowing
    uint256 public constant MAX_AAVE_LTV = 8000; // 80%

    /// @notice Maximum price feed staleness allowed (upgradeable)
    uint256 public maxPriceStaleness;

    /// @notice Loan-to-value ratio for Morpho borrowing
    uint256 public morphoLtv;

    /// @notice Loan-to-value ratio for Aave borrowing
    uint256 public aaveLtv;

    /// @notice Chainlink price feed for ETH/USD
    IAggregatorV3Interface public ethUsdPriceFeed;

    /// @notice Chainlink price feed for stETH/ETH
    IAggregatorV3Interface public wstEthEthPriceFeed;

    /// @notice Constructs the MangroveUsdcWethLidoLoopyVault
    /// @param owner Address of the vault owner
    /// @param usdc Address of the USDC token
    /// @param weth Address of the WETH token
    /// @param stEth Address of the stETH token
    /// @param aavePool Address of the Aave lending pool
    /// @param aaveOracle Address of the Aave oracle
    /// @param morpho Address of the Morpho protocol
    /// @param swapper Address of the swap module
    /// @param ethUsdPriceFeed Address of the ETH/USD Chainlink price feed
    /// @param wstEthEthPriceFeed Address of the wstETH/ETH Chainlink price feed
    /// @param curator Address of the curator
    /// @param guardian Address of the guardian
    /// @param feeRecipient Address that receives fees
    /// @param allocator Address of the allocator
    /// @param ghostbook Address of the Mangrove ghostbook
    /// @param morphoBorrowParams Morpho market params for stETH-WETH market
    /// @param initialTimelock Initial timelock duration
    /// @param maxIterations Maximum number of loop iterations allowed
    /// @param targetLeverage Target leverage multiplier (in basis points)
    /// @param aaveLtv LTV ratio for Aave borrowing
    /// @param morphoLtv LTV ratio for Morpho borrowing
    /// @param maxPriceStaleness Maximum allowed staleness for price feeds
    /// @param fee Fee amount in basis points
    /// @param autoExecuteOnDeposit Whether to automatically execute the loop strategy on deposits
    /// @param name Name of the vault token
    /// @param symbol Symbol of the vault token
    struct VaultParams {
        address owner;
        address usdc;
        address weth;
        address stEth;
        address aavePool;
        address aaveOracle;
        address morpho;
        address swapper;
        address ethUsdPriceFeed;
        address wstEthEthPriceFeed;
        address curator;
        address guardian;
        address feeRecipient;
        address allocator;
        IMangroveGhostbook ghostbook;
        MarketParams morphoBorrowParams;
        uint256 initialTimelock;
        uint256 maxIterations;
        uint256 targetLeverage;
        uint256 aaveLtv;
        uint256 morphoLtv;
        uint256 maxPriceStaleness;
        uint96 fee;
        bool autoExecuteOnDeposit;
        string name;
        string symbol;
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
        require(params.wstEthEthPriceFeed != address(0), "Zero stETH/ETH oracle");
        require(params.maxPriceStaleness > 0, "Zero max price staleness");

        usdc = IERC20(params.usdc);
        weth = IERC20(params.weth);
        stEth = IERC20(params.stEth);
        aavePool = IAavePool(params.aavePool);
        oracle = IAaveOracle(params.aaveOracle);
        morpho = IMorpho(params.morpho);
        _morphoBorrowParams = params.morphoBorrowParams;
        morphoLtv = params.morphoLtv;
        aaveLtv = params.aaveLtv;
        morphoBorrowId = params.morphoBorrowParams.id();
        maxIterations = params.maxIterations;
        targetLeverage = params.targetLeverage;
        swapper = ISwapModule(params.swapper);
        ghostbook = params.ghostbook;
        ethUsdPriceFeed = IAggregatorV3Interface(params.ethUsdPriceFeed);
        wstEthEthPriceFeed = IAggregatorV3Interface(params.wstEthEthPriceFeed);
        maxPriceStaleness = params.maxPriceStaleness;
        autoExecuteOnDeposit = params.autoExecuteOnDeposit;

        curator = params.curator;
        guardian = params.guardian;
        feeRecipient = params.feeRecipient;
        isAllocator[params.allocator] = true;
        fee = params.fee;

        // Verify that the market exists and has the correct tokens
        MarketParams memory marketParams = morpho.idToMarketParams(morphoBorrowId);
        require(marketParams.loanToken == params.weth, "Invalid loan token in Morpho market");
        require(marketParams.collateralToken == params.stEth, "Invalid collateral token in Morpho market");

        // Approve tokens for protocol interactions
        usdc.forceApprove(params.aavePool, type(uint256).max);
        weth.forceApprove(params.swapper, type(uint256).max);
        weth.forceApprove(params.aavePool, type(uint256).max);
        weth.forceApprove(params.morpho, type(uint256).max);
        weth.forceApprove(address(params.ghostbook), type(uint256).max);
        stEth.forceApprove(params.morpho, type(uint256).max);
        stEth.forceApprove(params.swapper, type(uint256).max);
        stEth.forceApprove(address(params.ghostbook), type(uint256).max);
        usdc.forceApprove(params.swapper, type(uint256).max);
    }

    /// @notice Sets whether deposits should automatically execute the loop strategy
    /// @dev Only callable by the owner
    /// @param _enabled Whether to enable auto-execution on deposits
    function setAutoExecuteOnDeposit(bool _enabled) external onlyOwner {
        autoExecuteOnDeposit = _enabled;
        emit SetAutoExecuteOnDeposit(_enabled);
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

    /// @notice Sets the target LTV for Aave borrowing
    /// @dev Only callable by the owner
    /// @param _aaveLtv New target LTV for Aave (in basis points)
    function setAaveLtv(uint256 _aaveLtv) external onlyOwner {
        require(_aaveLtv > 0, "Zero Aave LTV");
        if (_aaveLtv > MAX_AAVE_LTV) revert AaveLtvTooHigh();
        aaveLtv = _aaveLtv;
        emit SetAaveLtv(_aaveLtv);
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

    /// @notice Accepts a pending swap module after timelock has expired
    /// @dev Can be called by anyone after timelock period
    function acceptSwapModule() external afterTimelock(pendingSwapModule.validAt) {
        address newSwapModule = pendingSwapModule.value;

        // Approve the new swap module for stETH
        stEth.forceApprove(address(swapper), 0); // Remove approval from old swapper
        stEth.forceApprove(newSwapModule, type(uint256).max); // Approve new swapper
        usdc.forceApprove(address(swapper), 0); // Remove approval from old swapper
        usdc.forceApprove(newSwapModule, type(uint256).max); // Approve new swapper
        weth.forceApprove(address(swapper), 0); // Remove approval from old swapper
        weth.forceApprove(newSwapModule, type(uint256).max); // Approve new swapper

        swapper = ISwapModule(newSwapModule);

        emit SetSwapModule(_msgSender(), newSwapModule);

        delete pendingSwapModule;
    }

    /// @notice Sets the maximum number of loop iterations
    /// @dev Only callable by the owner
    /// @param _maxIterations New maximum number of iterations
    function setMaxIterations(uint256 _maxIterations) external onlyOwner {
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
        uint256 totalPositionValue = usdcValue + getStEthValueInUsdc();

        uint256 leverage = totalPositionValue * BASIS_POINTS / usdcValue;
        return leverage;
    }

    /// @inheritdoc IERC4626
    function totalAssets() public view override returns (uint256) {
        uint256 totalUsdcHoldings = usdc.balanceOf(address(this)) + _totalUsdcCollateral();

        uint256 totalWethDebtInUsdc = getWethDebtInUsdc();

        uint256 totalStEthPositionValue = getStEthValueInUsdc();

        uint256 result = totalUsdcHoldings + totalStEthPositionValue - totalWethDebtInUsdc;

        return result;
    }

    /// @notice Calculates the total USDC collateral in the vault
    /// @return Total USDC collateral in the vault
    function _totalUsdcCollateral() private view returns (uint256) {
        (uint256 usdCollateral,,,,,) = aavePool.getUserAccountData(address(this));
        uint256 usdcPrice = oracle.getAssetPrice(address(usdc));
        return usdCollateral * 1e6 / usdcPrice;
    }

    /// @inheritdoc IERC4626
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        // Accrue fees before deposit
        uint256 newTotalAssets = _accrueFee();

        // Update lastTotalAssets to avoid inconsistent state in re-entrant context
        // It will be updated again after the deposit
        lastTotalAssets = newTotalAssets;

        IERC20(asset()).safeTransferFrom(_msgSender(), address(this), assets);

        if (autoExecuteOnDeposit) {
            // Execute the looping strategy
            IMangroveGhostbook.ModuleData memory data;
            assets -= _executeLoopStrategy(assets, 0, IMangroveGhostbook.Tick.wrap(0), data);
        }

        // Calculate shares based on updated total assets
        shares = _convertToSharesWithTotals(assets, totalSupply(), newTotalAssets, Math.Rounding.Floor);

        _mint(receiver, shares);
        emit Deposit(_msgSender(), receiver, assets, shares);

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

        (, shares) = __withdraw(_msgSender(), receiver, owner, assets, shares, newTotalAssets);
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        uint256 newTotalAssets = _accrueFee();

        // Do not call expensive `maxRedeem` and optimistically redeem shares.
        assets = _convertToAssetsWithTotals(shares, totalSupply(), newTotalAssets, Math.Rounding.Floor);

        // `newTotalAssets - assets` may be a little off from `totalAssets()`.
        _updateLastTotalAssets(newTotalAssets.zeroFloorSub(assets));

        (assets,) = __withdraw(_msgSender(), receiver, owner, assets, shares, newTotalAssets);
    }

    /// @dev Custom withdraw function that unwinds the loop position before withdrawing
    /// @param caller The caller of the withdraw function
    /// @param receiver The receiver of the assets
    /// @param owner The owner of the shares
    /// @param assets The amount of assets to withdraw
    /// @param shares The amount of shares to withdraw
    /// @return assets The amount of assets withdrawn
    /// @return shares The amount of shares withdrawn
    /// @param totalAssetsBefore The total assets before the withdraw
    function __withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares,
        uint256 totalAssetsBefore
    )
        private
        returns (uint256, uint256)
    {
        caller; // Silence compiler warnings
        IMangroveGhostbook.ModuleData memory data;

        // Store initial state for precise calculations
        uint256 initialTotalSupply = totalSupply();
        uint256 initialSharePrice = totalAssetsBefore * 1e18 / initialTotalSupply; // Store with precision

        // Unwind loop based on withdrawal amount
        uint256 actualAssetsWithdrawn;
        if (assets == totalAssetsBefore) {
            actualAssetsWithdrawn = _unwindLoop();
        } else {
            actualAssetsWithdrawn = _unwindLoopAsNeeded(assets, 0, IMangroveGhostbook.Tick.wrap(0), data);
        }

        // Perform the actual withdrawal (burns shares)
        super._withdraw(_msgSender(), receiver, owner, actualAssetsWithdrawn, shares);

        // Calculate new state after withdrawal
        uint256 newTotalSupply = totalSupply(); // This is already reduced by 'shares'
        uint256 newTotalAssets = totalAssets(); // This should reflect actual current assets
        
        // Only mint correction shares if there are remaining shares and supply > 0
        if (newTotalSupply > 0) {
            // Calculate what the total assets should be to maintain the initial share price
            uint256 expectedTotalAssets = newTotalSupply * initialSharePrice / 1e18;

            if (newTotalAssets > expectedTotalAssets) {
                // We have excess assets - need to mint shares to dilute the price back down
                uint256 excessAssets = newTotalAssets - expectedTotalAssets;

                // Calculate shares to mint: excessAssets / currentSharePrice
                // But we want to maintain the original share price, so:
                // sharesToMint = excessAssets * newTotalSupply / expectedTotalAssets
                uint256 sharesToMint = _convertToSharesWithTotals(excessAssets, newTotalSupply, expectedTotalAssets, Math.Rounding.Floor);

                if (sharesToMint > 0) {
                    _mint(address(this), sharesToMint);
                }
            }
        }

        return (actualAssetsWithdrawn, shares);
    }

    /// @notice Manually executes the loop strategy for uninvested assets
    /// @dev Only callable by curator or allocator roles
    /// @param tickSpacing The tick spacing for any swaps needed
    /// @param maxTick The maximum tick for swaps
    /// @param moduleData Additional data for the swap module
    function executeLoopStrategy(
        uint256 assets,
        uint256 tickSpacing,
        IMangroveGhostbook.Tick maxTick,
        IMangroveGhostbook.ModuleData memory moduleData
    )
        external
        onlyAllocatorRole
    {
        // Accrue fees first
        uint256 newTotalAssets = _accrueFee();
        lastTotalAssets = newTotalAssets;

        // Execute the strategy
        _executeLoopStrategy(assets, tickSpacing, maxTick, moduleData);

        // Update lastTotalAssets after strategy execution
        _updateLastTotalAssets(totalAssets());

        emit Rebalanced(currentLeverageFactor(), targetLeverage);
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

        // Calculate debt increase/decrease based on current assets and leverage difference
        uint256 assetsDelta = totalAssets() * leverageDelta / (BASIS_POINTS - leverageDelta);

        if (currentLeverage < targetLeverage) {
            _increaseDebt(assetsDelta, tickSpacing, maxTick, moduleData);
        } else {
            _unwindLoopAsNeeded(assetsDelta, tickSpacing, maxTick, moduleData);
        }

        _updateLastTotalAssets(totalAssets());
        emit Rebalanced(currentLeverageFactor(), targetLeverage);
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
    function _executeLoopStrategy(
        uint256 amount,
        uint256 tickSpacing,
        IMangroveGhostbook.Tick maxTick,
        IMangroveGhostbook.ModuleData memory moduleData
    )
        private
        returns (uint256 losses)
    {
        if (amount == 0) return 0;

        // Supply USDC to Aave as collateral
        aavePool.supply(address(usdc), amount, address(this), 0);

        // Get initial state
        uint256 currentDebtUsdc = getWethDebtInUsdc();
        uint256 totalEquityUsdc = totalAssets();

        // Calculate total debt needed for target leverage
        // Leverage = TotalValue / Equity, where TotalValue = Equity + Debt
        // So: TargetLeverage = (Equity + Debt) / Equity
        // Rearranging: Debt = Equity * (TargetLeverage - 1)
        uint256 targetTotalDebtUsdc = totalEquityUsdc * (targetLeverage - BASIS_POINTS) / BASIS_POINTS;

        // Calculate additional debt needed
        uint256 additionalDebtUsdc = targetTotalDebtUsdc > currentDebtUsdc ? targetTotalDebtUsdc - currentDebtUsdc : 0;

        if (additionalDebtUsdc == 0) return amount;

        // Call _increaseDebt with the additional debt needed
        _increaseDebt(additionalDebtUsdc, tickSpacing, maxTick, moduleData);

        return totalEquityUsdc - totalAssets();
    }

    /// @notice Increases the debt by borrowing WETH from Aave and Morpho
    /// @param debtIncreaseUsdc Debt increase in USDC terms
    /// @param tickSpacing The tick spacing for any swaps needed during borrowing
    /// @param maxTick The maximum tick for the swap
    /// @param moduleData Additional data for the swap module
    function _increaseDebt(
        uint256 debtIncreaseUsdc,
        uint256 tickSpacing,
        IMangroveGhostbook.Tick maxTick,
        IMangroveGhostbook.ModuleData memory moduleData
    )
        private
    {
        // Convert USDC debt to WETH amount
        uint256 totalWethToBorrow = _convertUsdcToWethAmount(debtIncreaseUsdc);

        // Initial borrow from Aave
        (uint256 totalBorrowedWeth, uint256 stEthReceived) =
            _executeInitialBorrow(totalWethToBorrow, tickSpacing, maxTick, moduleData);

        // Check leverage after first borrow
        uint256 currentLeverage = currentLeverageFactor();

        // If we've already reached or exceeded target, stop here
        if (currentLeverage >= targetLeverage) {
            return;
        }

        // Continue with loop iterations if needed
        _executeLoopIterations(totalWethToBorrow, totalBorrowedWeth, stEthReceived, tickSpacing, maxTick, moduleData);
    }

    function _convertUsdcToWethAmount(uint256 debtIncreaseUsdc) private view returns (uint256) {
        uint256 wethPrice = oracle.getAssetPrice(address(weth));
        uint256 usdcPrice = oracle.getAssetPrice(address(usdc));

        // Total WETH to borrow to achieve the target debt
        return (debtIncreaseUsdc * usdcPrice * 1e12) / wethPrice;
    }

    function _executeInitialBorrow(
        uint256 totalWethToBorrow,
        uint256 tickSpacing,
        IMangroveGhostbook.Tick maxTick,
        IMangroveGhostbook.ModuleData memory moduleData
    )
        private
        returns (uint256 totalBorrowedWeth, uint256 stEthReceived)
    {
        // Calculate what we can borrow from Aave first
        uint256 aaveBorrowCapacity = _calculateBorrowCapacityAave();

        // Only borrow what Aave allows or what's needed, whichever is less
        uint256 initialBorrowAmount = totalWethToBorrow > aaveBorrowCapacity ? aaveBorrowCapacity : totalWethToBorrow;

        // If we're doing a single iteration, reduce the borrow amount
        if (maxIterations == 1 && targetLeverage < 20_000) {
            uint256 adjustmentFactor = BASIS_POINTS * BASIS_POINTS / targetLeverage;
            initialBorrowAmount = initialBorrowAmount * adjustmentFactor / BASIS_POINTS;
        }

        // Initial borrow from Aave
        totalBorrowedWeth = 0;
        if (initialBorrowAmount > 0) {
            aavePool.borrow(address(weth), initialBorrowAmount, 2, 0, address(this));
            totalBorrowedWeth = initialBorrowAmount;
        }

        // Swap WETH to stETH
        stEthReceived = _performSwap(false, initialBorrowAmount, tickSpacing, maxTick, moduleData);

        return (totalBorrowedWeth, stEthReceived);
    }

    function _executeLoopIterations(
        uint256 totalWethToBorrow,
        uint256 totalBorrowedWeth,
        uint256 stEthReceived,
        uint256 tickSpacing,
        IMangroveGhostbook.Tick maxTick,
        IMangroveGhostbook.ModuleData memory moduleData
    )
        private
    {
        for (uint256 i = 0; i < maxIterations && totalBorrowedWeth < totalWethToBorrow; i++) {
            // Supply stETH to Morpho as collateral
            morpho.supplyCollateral(_morphoBorrowParams, stEthReceived, address(this), "");

            // Calculate how much more we can borrow
            uint256 morphoBorrowCapacity = _calculateBorrowCapacityMorpho();
            if (morphoBorrowCapacity == 0) break;

            // Calculate remaining amount needed
            uint256 remainingWethNeeded = totalWethToBorrow - totalBorrowedWeth;

            // Borrow the minimum of capacity and need
            uint256 morphoBorrowAmount = _calculateMorphoBorrowAmount(morphoBorrowCapacity, remainingWethNeeded);

            // Borrow WETH from Morpho
            (uint256 borrowedWeth,) =
                morpho.borrow(_morphoBorrowParams, morphoBorrowAmount, 0, address(this), address(this));

            totalBorrowedWeth += borrowedWeth;

            // Swap new WETH to stETH for next iteration
            stEthReceived = _performSwap(false, borrowedWeth, tickSpacing, maxTick, moduleData);

            emit LoopIteration(i + 1, borrowedWeth, stEthReceived);

            // Check if we've reached target leverage
            if (currentLeverageFactor() >= targetLeverage) {
                break;
            }
        }
    }

    function _calculateMorphoBorrowAmount(
        uint256 morphoBorrowCapacity,
        uint256 remainingWethNeeded
    )
        private
        view
        returns (uint256)
    {
        uint256 morphoBorrowAmount =
            remainingWethNeeded > morphoBorrowCapacity ? morphoBorrowCapacity : remainingWethNeeded;

        // For last iteration or when close to target, be more conservative
        uint256 currentLeverage = currentLeverageFactor();
        uint256 leverageGap = targetLeverage - currentLeverage;
        if (leverageGap < 500) {
            // Less than 5% to go - scale down proportionally
            morphoBorrowAmount = morphoBorrowAmount * leverageGap / 500;
        }

        return morphoBorrowAmount;
    }

    /// @notice Helper function to perform swaps
    /// @param stEthToWeth Direction of the swap (true for stETH→WETH, false for WETH→stETH)
    /// @param amountIn Amount of input token to swap
    /// @param tickSpacing The tick spacing for the swap
    /// @param maxTick The maximum tick for the swap
    /// @param moduleData Additional data for the swap module
    /// @return amountOut Amount of output token received
    function _performSwap(
        bool stEthToWeth,
        uint256 amountIn,
        uint256 tickSpacing,
        IMangroveGhostbook.Tick maxTick,
        IMangroveGhostbook.ModuleData memory moduleData
    )
        private
        returns (uint256)
    {
        if (tickSpacing == 0) {
            return _fastSwap(stEthToWeth, amountIn);
        } else {
            return _optimalSwap(stEthToWeth, amountIn, tickSpacing, maxTick, moduleData);
        }
    }

    /// @notice Unwinds the loop position completely
    /// @dev Repays all WETH debt and redeems all stETH
    function _unwindLoop() private returns (uint256 balance) {
        IMangroveGhostbook.ModuleData memory data;
        return _unwindLoopAsNeeded(totalAssets(), 0, IMangroveGhostbook.Tick.wrap(0), data);
    }

    /// @notice Unwinds only as much of the loop as needed to free up a specific amount of assets
    /// @param assetsNeeded Amount of assets (USDC) needed
    function _unwindLoopAsNeeded(
        uint256 assetsNeeded,
        uint256 tickSpacing,
        IMangroveGhostbook.Tick maxTick,
        IMangroveGhostbook.ModuleData memory moduleData
    )
        private
        returns (uint256)
    {
        uint256 directBalance = usdc.balanceOf(address(this));

        if (directBalance >= assetsNeeded) {
            return assetsNeeded;
        }

        uint256 additionalUsdcNeeded = assetsNeeded - directBalance;

        uint256 netPositionValue = totalAssets();

        // If we can't free up enough funds, unwind everything
        if (netPositionValue < additionalUsdcNeeded) {
            return _unwindLoop();
        }

        // Calculate partial unwind ratio
        uint256 unwindRatio;
        if (assetsNeeded >= totalAssets()) {
            unwindRatio = BASIS_POINTS; // 100% unwind if we need all assets
        } else {
            unwindRatio = additionalUsdcNeeded * BASIS_POINTS / netPositionValue;
        }

        _executeFlashLoan(unwindRatio, tickSpacing, maxTick, moduleData);

        return usdc.balanceOf(address(this));
    }

    /// @notice Executes a flash loan to unwind a portion of the loop
    /// @param unwindRatio The ratio of the position to unwind (in basis points)
    /// @param tickSpacing The tick spacing for any swaps needed during unwinding
    /// @param maxTick The maximum tick for the swap
    /// @param moduleData Additional data for the swap module
    function _executeFlashLoan(
        uint256 unwindRatio,
        uint256 tickSpacing,
        IMangroveGhostbook.Tick maxTick,
        IMangroveGhostbook.ModuleData memory moduleData
    )
        private
    {
        uint256 wethToRepayAave = _calculateAaveRepayAmount(unwindRatio);
        uint256 wethToRepayMorpho = _calculateMorphoRepayAmount(unwindRatio);
        uint256 stEthToWithdrawMorpho = _getMorphoCollateral() * unwindRatio / BASIS_POINTS;
        uint256 flashLoanBorrow = wethToRepayAave + wethToRepayMorpho;

        morpho.flashLoan(
            address(weth),
            flashLoanBorrow,
            abi.encode(wethToRepayMorpho, stEthToWithdrawMorpho, unwindRatio, tickSpacing, maxTick, moduleData)
        );
    }

    /// @notice Calculates the amount of WETH to repay on Aave based on unwind ratio
    /// @param unwindRatio The ratio of the position to unwind (in basis points)
    /// @return Amount of WETH to repay on Aave
    function _calculateAaveRepayAmount(uint256 unwindRatio) private view returns (uint256) {
        uint256 aaveDebt = _getAaveDebt();
        uint256 aaveRepayAmount = aaveDebt * unwindRatio / BASIS_POINTS;
        return aaveRepayAmount;
    }

    /// @notice Calculates the amount of WETH to repay on Morpho based on unwind ratio
    /// @param unwindRatio The ratio of the position to unwind (in basis points)
    /// @return Amount of WETH to repay on Morpho
    function _calculateMorphoRepayAmount(uint256 unwindRatio) private view returns (uint256) {
        uint256 morphoDebt = _getMorphoDebt();
        uint256 morphoRepayAmount = morphoDebt * unwindRatio / BASIS_POINTS;
        return morphoRepayAmount;
    }

    /// @notice Performs a fast swap between stETH and WETH using the configured swapper
    /// @param stEthToWeth Direction of the swap (true for stETH→WETH, false for WETH→stETH)
    /// @param amountIn Amount of input token to swap
    /// @return amountOut Amount of output token received
    function _fastSwap(bool stEthToWeth, uint256 amountIn) private returns (uint256 amountOut) {
        address tokenIn = stEthToWeth ? address(stEth) : address(weth);
        address tokenOut = stEthToWeth ? address(weth) : address(stEth);
        amountOut = swapper.swap(tokenIn, tokenOut, amountIn);
        return amountOut;
    }

    /// @notice Performs an optimal swap between stETH and WETH using Mangrove Ghostbook
    /// @param stEthToWeth Direction of the swap (true for stETH→WETH, false for WETH→stETH)
    /// @param amountIn Amount of input token to swap
    /// @param tickSpacing The tick spacing for the swap
    /// @param maxTick The maximum tick for the swap
    /// @param moduleData Additional data for the swap module
    /// @return amountOut Amount of output token received
    function _optimalSwap(
        bool stEthToWeth,
        uint256 amountIn,
        uint256 tickSpacing,
        IMangroveGhostbook.Tick maxTick,
        IMangroveGhostbook.ModuleData memory moduleData
    )
        private
        returns (uint256 amountOut)
    {
        IMangroveGhostbook.OLKey memory key = IMangroveGhostbook.OLKey({
            outbound_tkn: stEthToWeth ? address(weth) : address(stEth),
            inbound_tkn: stEthToWeth ? address(stEth) : address(weth),
            tickSpacing: tickSpacing
        });
        (uint256 takerGot, uint256 takerGave,,) = ghostbook.marketOrderByTick(key, maxTick, amountIn, moduleData);
        if (takerGave < amountIn) revert SwapNotFullyConsumed();
        return takerGot;
    }

    /// @notice Returns the USDC value of the vault's position
    /// @dev Calculates the value of USDC supplied to Aave
    /// @return Value in USDC
    function _getUsdcValue() private view returns (uint256) {
        // Get USDC supplied as collateral on Aave
        uint256 usdcCollateral = _getUsdcCollateral();

        // Add direct USDC balance held by the vault
        uint256 directUsdcBalance = usdc.balanceOf(address(this));

        return usdcCollateral + directUsdcBalance;
    }

    /// @notice Returns the amount of USDC supplied as collateral on Aave
    /// @dev Converts totalCollateralBase from USD to USDC
    /// @return USDC collateral amount
    function _getUsdcCollateral() private view returns (uint256) {
        (uint256 totalCollateralBase,,,,,) = aavePool.getUserAccountData(address(this));

        // Convert totalCollateralBase (in USD) to USDC
        uint256 usdcPrice = oracle.getAssetPrice(address(usdc));
        return totalCollateralBase * 1e6 / usdcPrice;
    }

    /// @notice Returns the value of stETH held in USDC terms
    /// @dev Converts stETH value to USDC using price oracle
    /// @return Value in USDC
    function getStEthValueInUsdc() public view returns (uint256) {
        // Get stETH balance from Morpho
        uint256 suppliedStEth = _getMorphoCollateral();

        // Add direct stETH balance held by the vault
        uint256 directStEthBalance = stEth.balanceOf(address(this));

        uint256 totalStEth = suppliedStEth + directStEthBalance;

        // Get the price of stETH in terms of USDC
        uint256 stEthPriceInEth = getStEthPriceInEth(); // Price of stETH in ETH

        uint256 ethPriceInUsdc = getEthPriceInUsdc(); // Price of ETH in USDC

        uint256 stEthValueInUsdc = (totalStEth * stEthPriceInEth * ethPriceInUsdc) / (1e18 * 1e18) / 1e12;

        return stEthValueInUsdc;
    }

    /// @notice Returns the amount of stETH supplied as collateral on Morpho
    /// @return stETH collateral amount
    function _getMorphoCollateral() private view returns (uint256) {
        return morpho.position(morphoBorrowId, address(this)).collateral;
    }

    /// @notice Returns the amount of WETH debt on Morpho
    /// @return WETH debt amount
    function _getMorphoDebt() private view returns (uint256) {
        return morpho.expectedBorrowAssets(_morphoBorrowParams, address(this));
    }

    /// @notice Returns the value of WETH debt in USDC terms
    /// @dev Converts WETH debt to USDC using price oracle
    /// @return Value in USDC
    function getWethDebtInUsdc() public view returns (uint256) {
        // Get WETH debt from Aave
        uint256 aaveDebt = _getAaveDebt();

        // Get WETH debt from Morpho
        uint256 morphoDebt = _getMorphoDebt();
        uint256 totalWethDebt = aaveDebt + morphoDebt;

        uint256 wethPrice = oracle.getAssetPrice(address(weth));
        uint256 usdcPrice = oracle.getAssetPrice(address(usdc));

        return (totalWethDebt * wethPrice / usdcPrice) / 1e12;
    }

    /// @notice Calculates the borrow capacity on Morpho
    /// @return Borrow capacity in WETH
    function _calculateBorrowCapacityMorpho() private view returns (uint256) {
        // Get stETH supplied as collateral to Morpho
        uint256 suppliedStEth = morpho.position(morphoBorrowId, address(this)).collateral;

        // Apply the configurable LTV to determine borrow capacity
        // Convert stETH to WETH equivalent using the stETH/ETH exchange rate
        uint256 stEthPriceInEth = getStEthPriceInEth();

        uint256 totalBorrowCapacity = suppliedStEth * stEthPriceInEth * morphoLtv / (1e18 * BASIS_POINTS);

        // Subtract current Morpho debt from total borrow capacity
        uint256 currentMorphoDebt = _getMorphoDebt();

        // Return available capacity (or 0 if fully utilized)
        return currentMorphoDebt >= totalBorrowCapacity ? 0 : totalBorrowCapacity - currentMorphoDebt;
    }

    /// @notice Calculates the borrow capacity on Aave
    /// @dev Uses Aave's user account data to determine how much can be borrowed, capped by aaveLtv
    /// @return Borrow capacity in WETH
    function _calculateBorrowCapacityAave() private view returns (uint256) {
        // Get capacity in usdc
        (,, uint256 borrowCapacityUsd,,,) = aavePool.getUserAccountData(address(this));
        uint256 wethPrice = oracle.getAssetPrice(address(weth));

        // Calculate borrow capacity in WETH
        uint256 borrowCapacityWeth = borrowCapacityUsd * 1e18 / wethPrice;

        // Cap the borrow capacity by aaveLtv
        uint256 totalCollateralWeth = borrowCapacityWeth * BASIS_POINTS / aaveLtv;
        uint256 cappedBorrowCapacity = totalCollateralWeth * aaveLtv / BASIS_POINTS;

        return Math.min(borrowCapacityWeth, cappedBorrowCapacity);
    }

    /// @notice Gets the current health factor on Aave
    /// @dev Queries Aave for the health factor of this contract's position
    /// @return Health factor (scaled by 10000)
    function _getCurrentHealthFactorAave() private view returns (uint256) {
        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));

        // Aave returns health factor in RAY (1e27), we convert to our BASIS_POINTS scale (1e4)
        return (healthFactor * BASIS_POINTS) / 1e27;
    }

    /// @notice Gets the current debt on Aave
    /// @dev Queries Aave for the debt of this contract
    /// @return Debt amount in WETH
    function _getAaveDebt() private view returns (uint256) {
        (, uint256 wethDebtUsd,,,,) = aavePool.getUserAccountData(address(this));
        uint256 wethPrice = oracle.getAssetPrice(address(weth));
        uint256 wethDebtWeth = wethDebtUsd * 1e18 / wethPrice;
        return wethDebtWeth;
    }

    /// @notice Gets the current ETH price in USD from Chainlink Oracle
    /// @dev Returns price with 8 decimals precision, scaled to 18 decimals
    /// @return ETH price in USD (1e18 precision)
    function getEthPriceInUsdc() public view returns (uint256) {
        // Get the latest price from Chainlink
        (
            ,
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
            ,
            int256 price,
            /* uint startedAt */
            ,
            uint256 updatedAt,
            /* uint80 answeredInRound */
        ) = wstEthEthPriceFeed.latestRoundData();

        // Check if the price is stale
        if (block.timestamp - updatedAt > maxPriceStaleness) revert StalePrice();

        // Check if price is positive
        if (price <= 0) revert NegativePrice();

        // stETH/ETH price feed typically has 18 decimals
        uint256 stEthPriceInEth = uint256(price);

        return stEthPriceInEth;
    }

    /// @inheritdoc IMorphoFlashLoanCallback
    function onMorphoFlashLoan(uint256 borrowedWeth, bytes calldata data) external {
        (
            uint256 wethToRepayMorpho,
            uint256 stEthToWithdrawMorpho,
            uint256 unwindRatio,
            uint256 tickSpacing,
            IMangroveGhostbook.Tick maxTick,
            IMangroveGhostbook.ModuleData memory moduleData
        ) = abi.decode(
            data, (uint256, uint256, uint256, uint256, IMangroveGhostbook.Tick, IMangroveGhostbook.ModuleData)
        );

        uint256 morphoDebt = _getMorphoDebt();
        uint256 actualCollateral = _getMorphoCollateral();

        if (morphoDebt > 0 && wethToRepayMorpho > 0) {
            if (wethToRepayMorpho >= morphoDebt) {
                morpho.repay(
                    _morphoBorrowParams,
                    0,
                    morpho.position(morphoBorrowId, address(this)).borrowShares,
                    address(this),
                    ""
                );
            } else {
                morpho.repay(_morphoBorrowParams, wethToRepayMorpho, 0, address(this), "");
            }
        }

        stEthToWithdrawMorpho = Math.min(stEthToWithdrawMorpho, actualCollateral);
        uint256 extraStEthNeeded = stEth.balanceOf(address(this)) * unwindRatio / BASIS_POINTS;

        if (stEthToWithdrawMorpho > 0) {
            morpho.withdrawCollateral(_morphoBorrowParams, stEthToWithdrawMorpho, address(this), address(this));
        }

        uint256 stEthToSwap = stEthToWithdrawMorpho + extraStEthNeeded;

        if (stEthToSwap > 0) {
            if (IMangroveGhostbook.Tick.unwrap(maxTick) == 0) {
                _fastSwap(true, stEthToSwap);
            } else {
                _optimalSwap(true, stEthToSwap, tickSpacing, maxTick, moduleData);
            }
        }

        uint256 aaveDebt = _getAaveDebt();
        uint256 aaveRepayAmount = aaveDebt * unwindRatio / BASIS_POINTS;

        if (aaveDebt > 0 && aaveRepayAmount > 0) {
            aavePool.repay(address(weth), aaveRepayAmount, 2, address(this));

            uint256 aaveBalance = _getUsdcCollateral();
            uint256 aaveWithdrawAmount = aaveBalance * aaveRepayAmount / aaveDebt;

            aavePool.withdraw(address(usdc), aaveWithdrawAmount, address(this));
        }
        // Use some of the withdrawn usdc to repay help repay the flashloan
        _ensureWethAvailability(borrowedWeth);
    }

    /// @notice Ensures enough WETH is available by swapping USDC if needed
    /// @param borrowedWeth Amount of WETH that needs to be available
    /// @return wethBalance The final WETH balance after ensuring availability
    function _ensureWethAvailability(uint256 borrowedWeth) private returns (uint256) {
        uint256 wethBalance = weth.balanceOf(address(this));
        uint256 extraWethNeeded = borrowedWeth > wethBalance ? borrowedWeth - wethBalance : 0;

        if (extraWethNeeded > 0) {
            swapper.swapExactAmountOut(address(usdc), address(weth), extraWethNeeded);
        }

        return weth.balanceOf(address(this));
    }
}
