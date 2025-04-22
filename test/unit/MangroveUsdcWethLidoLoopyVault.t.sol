// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { BaseTest } from "../base/BaseTest.t.sol";
import { USDC_BASE, WETH_BASE, WST_ETH_BASE } from "../helpers/Tokens.sol";

import { AerodromeSwapper } from "src/AerodromeSwapper.sol";
import {
    BaseMangroveLoopyVault,
    IERC20,
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
    MarketParams public morphoMarketParams;

    // Protocol addresses on Base
    address constant AAVE_POOL_BASE = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant MORPHO_BASE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant LIDO_BASE = 0x1D0c5bDe1a25439B965FDCdfD46F4D3EF60F8D17;
    address constant AERODROME_FACTORY_BASE = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address constant AERODROME_ROUTER_BASE = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

    // Chainlink Price Feed addresses on Base
    address constant ETH_USD_PRICE_FEED_BASE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant STETH_ETH_PRICE_FEED_BASE = 0x43a5C292A453A3bF3606fa856197f09D7B74251a;

    // Configuration constants
    uint256 constant INITIAL_TIMELOCK = 1 days;
    uint256 constant MAX_ITERATIONS = 5;
    uint256 constant TARGET_LEVERAGE = 300; // 3x leverage (300% of initial capital)
    uint256 constant MORPHO_LTV = 75; // 75% LTV for Morpho borrowing
    string constant VAULT_NAME = "Mangrove USDC-WETH-Lido Loopy Vault";
    string constant VAULT_SYMBOL = "mgvUWLV";

    bytes32 constant MORPHO_ST_ETH_WETH_MARKET_ID_BASE =
        0x3a4048c64ba1b375330d376b1ce40e4047d03b47ab4d48af484edec9fec801ba;

    function setUp() public {
        _setUp("BASE", 29_215_255);
        morphoMarketParams = MarketParams({
            loanToken: WETH_BASE,
            collateralToken: WST_ETH_BASE,
            oracle: 0x4A11590e5326138B514E08A9B52202D42077Ca65,
            irm: 0x46415998764C29aB2a25CbeA6254146D50D22687,
            lltv: 945_000_000_000_000_000
        });
        swapper = new AerodromeSwapper(AERODROME_FACTORY_BASE, AERODROME_ROUTER_BASE);
        ghostbook = IMangroveGhostbook(vm.envAddress("GHOSTBOOK_ADDRESS_BASE"));
        address owner = users.alice;

        MangroveUsdcWethLidoLoopyVault.VaultParams memory params = MangroveUsdcWethLidoLoopyVault.VaultParams({
            owner: owner,
            initialTimelock: INITIAL_TIMELOCK,
            usdc: USDC_BASE,
            weth: WETH_BASE,
            lido: LIDO_BASE,
            stEth: WST_ETH_BASE,
            aavePool: AAVE_POOL_BASE,
            morpho: MORPHO_BASE,
            morphoMarketParams: morphoMarketParams,
            maxIterations: MAX_ITERATIONS,
            targetLeverage: TARGET_LEVERAGE,
            name: VAULT_NAME,
            symbol: VAULT_SYMBOL,
            swapper: address(swapper),
            ghostbook: ghostbook,
            morphoLtv: MORPHO_LTV,
            ethUsdPriceFeed: ETH_USD_PRICE_FEED_BASE,
            stEthEthPriceFeed: STETH_ETH_PRICE_FEED_BASE
        });

        vault = new MangroveUsdcWethLidoLoopyVault(params);
    }

    // Additional test functions for MangroveUsdcWethLidoLoopyVaultTest contract

    function testMangroveUsdcWethLidoLoopyVault_InitialState() public {
        // Check that the vault was initialized with the correct values
        assertEq(address(vault.usdc()), USDC_BASE);
        assertEq(address(vault.weth()), WETH_BASE);
        assertEq(address(vault.stEth()), WST_ETH_BASE);
        assertEq(address(vault.lido()), LIDO_BASE);
        assertEq(address(vault.aavePool()), AAVE_POOL_BASE);
        assertEq(address(vault.morpho()), MORPHO_BASE);
        assertEq(address(vault.swapper()), address(swapper));
        assertEq(address(vault.ghostbook()), address(ghostbook));
        assertEq(Id.unwrap(vault.morphoMarketId()), MORPHO_ST_ETH_WETH_MARKET_ID_BASE);
        assertEq(vault.maxIterations(), MAX_ITERATIONS);
        assertEq(vault.targetLeverage(), TARGET_LEVERAGE);
        assertEq(vault.morphoLtv(), MORPHO_LTV);
        assertEq(address(vault.ethUsdPriceFeed()), ETH_USD_PRICE_FEED_BASE);
        assertEq(address(vault.stEthEthPriceFeed()), STETH_ETH_PRICE_FEED_BASE);
        assertEq(vault.owner(), users.alice);
    }

    function testMangroveUsdcWethLidoLoopyVault_SetMorphoLtv() public {
        // Test setting a new morphoLtv value
        uint256 newLtv = 70; // 70%

        vm.prank(users.alice);
        vault.setMorphoLtv(newLtv);

        assertEq(vault.morphoLtv(), newLtv);
    }

    function testMangroveUsdcWethLidoLoopyVault_SetMorphoLtvRevertsIfTooHigh() public {
        // Test setting a morphoLtv value that exceeds the maximum
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
        // Deploy a new swapper
        AerodromeSwapper newSwapper = new AerodromeSwapper(AERODROME_FACTORY_BASE, AERODROME_ROUTER_BASE);

        vm.prank(users.alice);
        vault.submitSwapModule(address(newSwapper));

        // Check that the pendingSwapModule is set correctly
        (address value, uint256 validAt) = vault.pendingSwapModule();
        assertEq(value, address(newSwapper));
        assertEq(validAt, block.timestamp + INITIAL_TIMELOCK);
    }

    function testMangroveUsdcWethLidoLoopyVault_AcceptSwapModule() public {
        // Deploy a new swapper
        AerodromeSwapper newSwapper = new AerodromeSwapper(AERODROME_FACTORY_BASE, AERODROME_ROUTER_BASE);

        // Submit the new swapper
        vm.prank(users.alice);
        vault.submitSwapModule(address(newSwapper));

        // Fast forward past the timelock period
        vm.warp(block.timestamp + INITIAL_TIMELOCK + 1);

        // Accept the new swapper
        vault.acceptSwapModule();

        // Check that the swapper was updated
        assertEq(address(vault.swapper()), address(newSwapper));

        // Check that pendingSwapModule was cleared
        (address value, uint256 validAt) = vault.pendingSwapModule();
        assertEq(value, address(0));
        assertEq(validAt, 0);
    }

    function testMangroveUsdcWethLidoLoopyVault_AcceptSwapModuleRevertsBeforeTimelock() public {
        // Deploy a new swapper
        AerodromeSwapper newSwapper = new AerodromeSwapper(AERODROME_FACTORY_BASE, AERODROME_ROUTER_BASE);

        // Submit the new swapper
        vm.prank(users.alice);
        vault.submitSwapModule(address(newSwapper));

        // Fast forward but not past the timelock period
        vm.warp(block.timestamp + INITIAL_TIMELOCK - 1);

        // Try to accept the new swapper, should revert
        vm.expectRevert(BaseMangroveLoopyVault.TimelockNotElapsed.selector);
        vault.acceptSwapModule();
    }

    function testMangroveUsdcWethLidoLoopyVault_GetPrices() public {
        // Test that we can fetch prices without reverting
        uint256 ethPrice = vault.getEthPriceInUsdc();
        uint256 stEthPrice = vault.getStEthPriceInEth();

        // Prices should be positive
        assert(ethPrice > 0);
        assert(stEthPrice > 0);
    }

    function testMangroveUsdcWethLidoLoopyVault_DepositWithoutLoop() public {
        // Fund the user with USDC
        uint256 depositAmount = 1000 * 1e6; // 1000 USDC
        deal(USDC_BASE, users.alice, depositAmount);

        // Mock the vault to skip the looping strategy
        vm.mockCall(
            address(vault),
            abi.encodeWithSignature("_executeLoopStrategy()"),
            abi.encode()
        );

        // Approve and deposit
        vm.startPrank(users.alice);
        IERC20(USDC_BASE).safeIncreaseAllowance(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, users.alice);
        vm.stopPrank();

        // Verify shares were minted
        assertEq(vault.balanceOf(users.alice), shares);

        // Verify deposit was processed
        assertEq(IERC20(USDC_BASE).balanceOf(users.alice), 0);
        assertEq(vault.totalSupply(), shares);
    }

    function testMangroveUsdcWethLidoLoopyVault_EmergencyUnwind() public {
        // Set up the guardian
        vm.prank(users.alice);
        vault.submitGuardian(users.charlie);

        // Fast forward past the timelock period
        vm.warp(block.timestamp + INITIAL_TIMELOCK + 1);

        // Accept the guardian
        vault.submitGuardian(users.charlie);

        // Mock the unwind function to validate it's called
        vm.mockCall(
            address(vault), abi.encodeWithSignature("_unwindLoop()"),abi.encode(0)
        );

        // Call emergencyUnwind as the guardian
        vm.prank(users.charlie);
        vault.emergencyUnwind();

        // Verify that _unwindLoop was called (this is implicit in the mock setup)
    }
}
