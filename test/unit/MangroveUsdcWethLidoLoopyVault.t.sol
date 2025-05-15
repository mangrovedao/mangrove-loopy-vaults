// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { BaseTest, console2 } from "../base/BaseTest.t.sol";
import { USDC_BASE, WETH_BASE, WST_ETH_BASE } from "../helpers/Tokens.sol";

import { VerboseWeth } from "../helpers/mock/VerboseWeth.sol";
import { AerodromeSwapper } from "src/AerodromeSwapper.sol";
import {
    BaseMangroveLoopyVault,
    IAggregatorV3Interface,
    IERC20,
    IERC4626,
    IMangroveGhostbook,
    ISwapModule,
    Id,
    MangroveUsdcWethLidoLoopyVault,
    MarketParams,
    SafeERC20
} from "src/MangroveUsdcWethLidoLoopyVault.sol";

contract MangroveUsdcWethLidoLoopyVaultTest is BaseTest {
    using SafeERC20 for IERC20;

    MangroveUsdcWethLidoLoopyVault public vault;
    AerodromeSwapper public swapper;
    IMangroveGhostbook public ghostbook;
    MarketParams public morphoBorrowParams;
    IERC4626 public morphoSupplyVault;
    MangroveUsdcWethLidoLoopyVault.VaultParams params;

    // Protocol addresses on Base
    address constant AAVE_POOL_BASE = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_ORACLE_ADDRESS = 0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156;
    address constant MORPHO_BASE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant AERODROME_FACTORY_BASE = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address constant AERODROME_ROUTER_BASE = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant AERODROME_WETH_ST_ETH_POOL_BASE = 0xA6385c73961dd9C58db2EF0c4EB98cE4B60651e8;
    address constant STETH_ETH_PRICE_FEED_BASE = 0x43a5C292A453A3bF3606fa856197f09D7B74251a;
    address constant ETH_USD_PRICE_FEED_BASE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    // Configuration constants
    uint256 constant INITIAL_TIMELOCK = 1 days;
    uint256 constant MAX_ITERATIONS = 30;
    uint256 constant TARGET_LEVERAGE = 17_000; // 2x leverage (200% of initial capital)
    uint256 constant MORPHO_LTV = 9000; // 90% LTV for Morpho borrowing
    uint256 constant AAVE_LTV = 5000; // 50% LTV for Aave borrowing
    string constant VAULT_NAME = "Mangrove USDC-WETH-Lido Loopy Vault";
    string constant VAULT_SYMBOL = "mgvUWLV";

    bytes32 constant MORPHO_ST_ETH_WETH_MARKET_ID_BASE =
        0x3a4048c64ba1b375330d376b1ce40e4047d03b47ab4d48af484edec9fec801ba;

    function setUp() public {
        _setUp("BASE", 25_269_187);
        VerboseWeth mockWeth = new VerboseWeth();

        // Fetch WETH balances before vm.etch
        uint256 morphoWethBalance = IERC20(WETH_BASE).balanceOf(MORPHO_BASE);
        uint256 aavePoolWethBalance = IERC20(WETH_BASE).balanceOf(AAVE_POOL_BASE);
        uint256 aerodromeRouterWethBalance = IERC20(WETH_BASE).balanceOf(AERODROME_ROUTER_BASE);
        uint256 aerodromeWethStEthPoolWethBalance = IERC20(WETH_BASE).balanceOf(AERODROME_WETH_ST_ETH_POOL_BASE);

        // Set mock bytecode WETH for easier debugging
        vm.etch(WETH_BASE, address(mockWeth).code);

        morphoBorrowParams = MarketParams({
            loanToken: WETH_BASE,
            collateralToken: WST_ETH_BASE,
            oracle: 0x4A11590e5326138B514E08A9B52202D42077Ca65,
            irm: 0x46415998764C29aB2a25CbeA6254146D50D22687,
            lltv: 945_000_000_000_000_000
        });

        swapper = new AerodromeSwapper(AERODROME_FACTORY_BASE, AERODROME_ROUTER_BASE);
        ghostbook = IMangroveGhostbook(vm.envAddress("GHOSTBOOK_ADDRESS_BASE"));
        address owner = users.alice;

        params = MangroveUsdcWethLidoLoopyVault.VaultParams({
            owner: owner,
            initialTimelock: INITIAL_TIMELOCK,
            usdc: USDC_BASE,
            weth: WETH_BASE,
            stEth: WST_ETH_BASE,
            aavePool: AAVE_POOL_BASE,
            aaveOracle: AAVE_ORACLE_ADDRESS,
            morpho: MORPHO_BASE,
            morphoBorrowParams: morphoBorrowParams,
            maxIterations: MAX_ITERATIONS,
            targetLeverage: TARGET_LEVERAGE,
            name: VAULT_NAME,
            symbol: VAULT_SYMBOL,
            swapper: address(swapper),
            aaveLtv: AAVE_LTV,
            ghostbook: ghostbook,
            morphoLtv: MORPHO_LTV,
            ethUsdPriceFeed: ETH_USD_PRICE_FEED_BASE,
            stEthEthPriceFeed: STETH_ETH_PRICE_FEED_BASE,
            maxPriceStaleness: 24 hours,
            curator: users.curator,
            guardian: users.guardian,
            feeRecipient: users.feeRecipient,
            allocator: users.allocator,
            fee: 0.1 ether,
            autoExecuteOnDeposit: true
        });

        vault = new MangroveUsdcWethLidoLoopyVault(params);
        _setUpLabels();
    }

    function _setUpLabels() internal {
        vm.label(USDC_BASE, "USDC");
        vm.label(WETH_BASE, "WETH");
        vm.label(WST_ETH_BASE, "WST_ETH");
        vm.label(AAVE_POOL_BASE, "AAVE_POOL");
        vm.label(MORPHO_BASE, "MORPHO");
        vm.label(AERODROME_FACTORY_BASE, "AERODROME_FACTORY");
        vm.label(AERODROME_ROUTER_BASE, "AERODROME_ROUTER");
        vm.label(ETH_USD_PRICE_FEED_BASE, "ETH_USD_PRICE_FEED");
        vm.label(STETH_ETH_PRICE_FEED_BASE, "STETH_ETH_PRICE_FEED");
        vm.label(address(ghostbook), "GHOSTBOOK");
        vm.label(address(swapper), "SWAPPER");
        vm.label(address(vault), "VAULT");
        vm.label(AERODROME_WETH_ST_ETH_POOL_BASE, "AERODROME_WETH_ST_ETH_POOL");
    }

    function mockEthPriceDecrease(uint256 percentDecrease) internal {
        // Get current price
        (, int256 currentPrice,,,) = IAggregatorV3Interface(ETH_USD_PRICE_FEED_BASE).latestRoundData();
        int256 newPrice = currentPrice * int256(100 - percentDecrease) / 100;

        // Mock the price feed
        vm.mockCall(
            ETH_USD_PRICE_FEED_BASE,
            abi.encodeWithSelector(IAggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(0), newPrice, uint256(0), block.timestamp, uint80(0))
        );
    }

    function mockEthPriceIncrease(uint256 percentIncrease) internal {
        // Get current price
        (, int256 currentPrice,,,) = IAggregatorV3Interface(ETH_USD_PRICE_FEED_BASE).latestRoundData();
        int256 newPrice = currentPrice * int256(100 + percentIncrease) / 100;

        // Mock the price feed
        vm.mockCall(
            ETH_USD_PRICE_FEED_BASE,
            abi.encodeWithSelector(IAggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(0), newPrice, uint256(0), block.timestamp, uint80(0))
        );
    }

    function mockStEthPriceIncrease(uint256 percentIncrease) internal {
        // Get current price
        (, int256 currentPrice,,,) = IAggregatorV3Interface(STETH_ETH_PRICE_FEED_BASE).latestRoundData();
        int256 newPrice = currentPrice * int256(100 + percentIncrease) / 100;

        // Mock the price feed
        vm.mockCall(
            STETH_ETH_PRICE_FEED_BASE,
            abi.encodeWithSelector(IAggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(0), newPrice, uint256(0), block.timestamp, uint80(0))
        );
    }

    function testMangroveUsdcWethLidoLoopyVault_InitialState() public {
        assertEq(address(vault.usdc()), USDC_BASE);
        assertEq(address(vault.weth()), WETH_BASE);
        assertEq(address(vault.stEth()), WST_ETH_BASE);
        assertEq(address(vault.aavePool()), AAVE_POOL_BASE);
        assertEq(address(vault.morpho()), MORPHO_BASE);
        assertEq(address(vault.swapper()), address(swapper));
        assertEq(address(vault.ghostbook()), address(ghostbook));
        assertEq(Id.unwrap(vault.morphoBorrowId()), MORPHO_ST_ETH_WETH_MARKET_ID_BASE);
        assertEq(vault.maxIterations(), MAX_ITERATIONS);
        assertEq(vault.targetLeverage(), TARGET_LEVERAGE);
        assertEq(vault.morphoLtv(), MORPHO_LTV);
        assertEq(address(vault.ethUsdPriceFeed()), ETH_USD_PRICE_FEED_BASE);
        assertEq(address(vault.stEthEthPriceFeed()), STETH_ETH_PRICE_FEED_BASE);
        assertEq(vault.owner(), users.alice);
        assertEq(vault.curator(), users.curator);
        assertEq(vault.guardian(), users.guardian);
        assertEq(vault.feeRecipient(), users.feeRecipient);
        assertEq(vault.isAllocator(users.allocator), true);
        assertEq(vault.fee(), 0.1 ether);
    }

    function testDeposit_WithFullLoopStrategy() public {
        uint256 depositAmount = 1000 * 1e6; // 1000 USDC
        deal(USDC_BASE, users.alice, depositAmount);

        vm.startPrank(users.alice);
        IERC20(USDC_BASE).safeIncreaseAllowance(address(vault), depositAmount);
        uint256 sharePriceBefore = vault.pricePerShare();
        uint256 shares = vault.deposit(depositAmount, users.alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(users.alice), shares);
        assertEq(IERC20(USDC_BASE).balanceOf(users.alice), 0);
        assertEq(IERC20(USDC_BASE).balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), shares);
        assertApproxEqRel(vault.totalAssets(), depositAmount, 0.05e18); // 5% tolerance
        assertGt(vault.currentLeverageFactor(), 10_000);
        if(vault.autoExecuteOnDeposit()) {
            assertApproxEqRel(vault.currentLeverageFactor(), params.targetLeverage, 1e18); // 1% tolerance
        }
        assertEq(vault.pricePerShare(), sharePriceBefore);
    }

    function testMangroveUsdcWethLidoLoopyVault_DepositWithoutLoop() public {
        uint256 depositAmount = 1000 * 1e6; // 1000 USDC
        deal(USDC_BASE, users.alice, depositAmount);

        vm.startPrank(users.alice);
        vault.setAutoExecuteOnDeposit(false);
        IERC20(USDC_BASE).safeIncreaseAllowance(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, users.alice);
        vm.stopPrank();
        assertEq(vault.balanceOf(users.alice), shares);
        assertEq(IERC20(USDC_BASE).balanceOf(users.alice), 0);
        assertEq(IERC20(USDC_BASE).balanceOf(address(vault)), depositAmount);
        assertApproxEqRel(vault.totalAssets(), depositAmount, 1e18); // 1% tolerance
        assertEq(vault.totalSupply(), shares);
    }

    function testMangroveUsdcWethLidoLoopyVault_RedeemPartial() public {
        testDeposit_WithFullLoopStrategy();

        uint256 initialShares = vault.balanceOf(users.alice);
        uint256 sharesToRedeem = initialShares / 10;
        uint256 totalAssets = vault.totalAssets();
        uint256 aliceBalance = IERC20(USDC_BASE).balanceOf(users.alice);
        uint256 initialPricePerShare = vault.pricePerShare();

        vm.startPrank(users.alice);
        uint256 assets = vault.redeem(sharesToRedeem, users.alice, users.alice);
        assertApproxEq(assets, totalAssets / 10, totalAssets / 100);
        vm.stopPrank();

        assertEq(vault.balanceOf(users.alice), initialShares - sharesToRedeem);
        assertEq(IERC20(USDC_BASE).balanceOf(users.alice), aliceBalance + assets);
        assertEq(IERC20(USDC_BASE).balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), initialShares - sharesToRedeem);
        assertApproxEq(vault.totalAssets(), totalAssets - assets, assets / 100);
        assertEq(vault.pricePerShare(), initialPricePerShare);
    }

    function testMangroveUsdcWethLidoLoopyVault_RedeemFullLoopStrategy() public {
        testDeposit_WithFullLoopStrategy();

        uint256 shares = vault.balanceOf(users.alice);
        uint256 totalAssets = vault.totalAssets();
        uint256 aliceBalance = IERC20(USDC_BASE).balanceOf(users.alice);

        vm.startPrank(users.alice);
        uint256 assets = vault.redeem(shares, users.alice, users.alice);
        assertApproxEq(assets, totalAssets, totalAssets / 100);
        vm.stopPrank();

        assertEq(vault.balanceOf(users.alice), 0);
        assertEq(IERC20(USDC_BASE).balanceOf(users.alice), aliceBalance + assets);
        assertEq(IERC20(USDC_BASE).balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), 0);
        assertApproxEq(vault.totalAssets(), 0, 2e6);
    }

    function testMangroveUsdcWethLidoLoopyVault_ReduceLeverage() public {
        testDeposit_WithFullLoopStrategy();
        uint256 newTargetLeverage = 15_000;

        address aerodromeFactory = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
        address aerodromeModule = 0xF2CACc9ca4eEac1bad53E208C738c728Ab3b381c;
        uint256 leverageFactorBefore = vault.currentLeverageFactor();
        vm.startPrank(users.alice);
        vault.setTargetLeverage(newTargetLeverage);
        IMangroveGhostbook.ModuleData memory data;
        vault.rebalance(
            0,
            IMangroveGhostbook.Tick.wrap(0),
           data
        );
        uint256 leverageFactorAfter = vault.currentLeverageFactor();
        assertApproxEqRel(leverageFactorAfter, newTargetLeverage, 1e18); // 1% tolerance
        assertLt(leverageFactorAfter, leverageFactorBefore);
    }

    function testMangroveUsdcWethLidoLoopyVault_IncreaseLeverage() public {
        vm.prank(users.alice);
        vault.setTargetLeverage(10_500);
        testDeposit_WithFullLoopStrategy();

        address aerodromeFactory = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
        address aerodromeModule = 0xF2CACc9ca4eEac1bad53E208C738c728Ab3b381c;
        uint256 leverageFactorBefore = vault.currentLeverageFactor();

        uint256 newTargetLeverage = 14_000;
        
        vm.startPrank(users.alice);
        vault.setTargetLeverage(newTargetLeverage);
        IMangroveGhostbook.ModuleData memory md;
        vault.rebalance(0, IMangroveGhostbook.Tick.wrap(0), md);
        uint256 leverageFactorAfter = vault.currentLeverageFactor();
        
        assertApproxEqRel(leverageFactorAfter, newTargetLeverage, 1e18); // 1% tolerance
        assertGt(leverageFactorAfter, leverageFactorBefore);
    }

    function testMangroveUsdcWethLidoLoopyVault_EmergencyUnwind() public {
        testDeposit_WithFullLoopStrategy();
        uint256 totalAssetsBefore = vault.totalAssets();

        vm.prank(users.alice);
        vault.emergencyUnwind();

        uint256 totalAssetsAfter = vault.totalAssets();

        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.005e18);
    }

    function testMangroveUsdcWethLidoLoopyVault_ExecuteLoopStrategy() public {
        vault.setAutoExecuteOnDeposit(false);
        testDeposit_WithFullLoopStrategy();
        vm.startPrank(users.alice);
        IMangroveGhostbook.ModuleData memory md;
        vault.executeLoopStrategy(vault.totalAssets(), 0,IMangroveGhostbook.Tick.wrap(0), md);
        assertApproxEqRel(vault.currentLeverageFactor(), params.targetLeverage, 1e18); 
    }
        

    function testMangroveUsdcWethLidoLoopyVault_MockStEthPriceIncrease() public {
        testDeposit_WithFullLoopStrategy();

        uint256 periodInDays = 90 days;

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 pricePerShareBefore = vault.pricePerShare();
        console2.log("Total Assets Before:", totalAssetsBefore);
        console2.log("Price Per Share Before:", pricePerShareBefore);

        skip(periodInDays);
        mockEthPriceIncrease(20); // weth/usdc increases 20%
        mockStEthPriceIncrease(2); // steth/weth increases 2%

        uint256 totalAssetsAfter = vault.totalAssets();
        uint256 pricePerShareAfter = vault.pricePerShare();
        console2.log("Total Assets After:", totalAssetsAfter);
        console2.log("Price Per Share After:", pricePerShareAfter);
       
        assertGt(totalAssetsAfter, totalAssetsBefore);
    }

    function testMangroveUsdcWethLidoLoopyVault_SetMorphoLtv() public {
        uint256 newLtv = 70; // 70%

        vm.prank(users.alice);
        vault.setMorphoLtv(newLtv);

        assertEq(vault.morphoLtv(), newLtv);
    }

    function testMangroveUsdcWethLidoLoopyVault_SetMorphoLtvRevertsIfTooHigh() public {
        uint256 tooHighLtv = vault.MAX_MORPHO_LTV() + 1;

        vm.prank(users.alice);
        vm.expectRevert(MangroveUsdcWethLidoLoopyVault.MorphoLtvTooHigh.selector);
        vault.setMorphoLtv(tooHighLtv);
    }

    function testMangroveUsdcWethLidoLoopyVault_SetMorphoLtvRevertsIfZero() public {
        vm.prank(users.alice);
        vm.expectRevert("Zero Morpho LTV");
        vault.setMorphoLtv(0);
    }

    function testMangroveUsdcWethLidoLoopyVault_SetMorphoLtvRevertsIfNotOwner() public {
        vm.prank(users.bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", users.bob));
        vault.setMorphoLtv(70);
    }

    function testMangroveUsdcWethLidoLoopyVault_SetMaxIterations() public {
        uint256 newMaxIterations = 10;

        vm.prank(users.alice);
        vault.setMaxIterations(newMaxIterations);

        assertEq(vault.maxIterations(), newMaxIterations);
    }

    function testMangroveUsdcWethLidoLoopyVault_SetTargetLeverage() public {
        uint256 newTargetLeverage = 250; // 2.5x

        vm.prank(users.alice);
        vault.setTargetLeverage(newTargetLeverage);

        assertEq(vault.targetLeverage(), newTargetLeverage);
    }

    function testMangroveUsdcWethLidoLoopyVault_SubmitSwapModule() public {
        AerodromeSwapper newSwapper = new AerodromeSwapper(AERODROME_FACTORY_BASE, AERODROME_ROUTER_BASE);

        vm.prank(users.alice);
        vault.submitSwapModule(address(newSwapper));

        (address value, uint256 validAt) = vault.pendingSwapModule();
        assertEq(value, address(newSwapper));
        assertEq(validAt, block.timestamp + INITIAL_TIMELOCK);
    }

    function testMangroveUsdcWethLidoLoopyVault_AcceptSwapModule() public {
        AerodromeSwapper newSwapper = new AerodromeSwapper(AERODROME_FACTORY_BASE, AERODROME_ROUTER_BASE);

        vm.prank(users.alice);
        vault.submitSwapModule(address(newSwapper));

        vm.warp(block.timestamp + INITIAL_TIMELOCK + 1);

        vault.acceptSwapModule();

        assertEq(address(vault.swapper()), address(newSwapper));

        (address value, uint256 validAt) = vault.pendingSwapModule();
        assertEq(value, address(0));
        assertEq(validAt, 0);
    }

    function testMangroveUsdcWethLidoLoopyVault_AcceptSwapModuleRevertsBeforeTimelock() public {
        AerodromeSwapper newSwapper = new AerodromeSwapper(AERODROME_FACTORY_BASE, AERODROME_ROUTER_BASE);

        vm.prank(users.alice);
        vault.submitSwapModule(address(newSwapper));

        vm.warp(block.timestamp + INITIAL_TIMELOCK - 1);

        vm.expectRevert(BaseMangroveLoopyVault.TimelockNotElapsed.selector);
        vault.acceptSwapModule();
    }

    function testMangroveUsdcWethLidoLoopyVault_GetPrices() public {
        uint256 ethPrice = vault.getEthPriceInUsdc();
        uint256 stEthPrice = vault.getStEthPriceInEth();

        assertGt(ethPrice, 0);
        assertGt(stEthPrice, 0);
    }
}

interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    /// @notice Fetch and sort the reserves for a pool
    /// @param tokenA       .
    /// @param tokenB       .
    /// @param stable       True if pool is stable, false if volatile
    /// @param _factory     Address of PoolFactory for tokenA and tokenB
    /// @return reserveA    Amount of reserves of the sorted token A
    /// @return reserveB    Amount of reserves of the sorted token B
    function getReserves(
        address tokenA,
        address tokenB,
        bool stable,
        address _factory
    )
        external
        view
        returns (uint256 reserveA, uint256 reserveB);

    /// @notice Perform chained getAmountOut calculations on any number of pools
    function getAmountsOut(uint256 amountIn, Route[] memory routes) external view returns (uint256[] memory amounts);

    /// @notice Swap one token for another
    /// @param amountIn     Amount of token in
    /// @param amountOutMin Minimum amount of desired token received
    /// @param routes       Array of trade routes used in the swap
    /// @param to           Recipient of the tokens received
    /// @param deadline     Deadline to receive tokens
    /// @return amounts     Array of amounts returned per route
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    )
        external
        returns (uint256[] memory amounts);
}
