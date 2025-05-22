// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AerodromeSwapper } from "../src/AerodromeSwapper.sol";
import { MangroveUsdcWethLidoLoopyVault } from "../src/MangroveUsdcWethLidoLoopyVault.sol";

import { IMangroveGhostbook } from "../src/interfaces/IMangroveGhostbook.sol";
import { Script } from "forge-std/Script.sol";

import { console } from "forge-std/console.sol";
import { Id, MarketParams } from "morpho-org-morpho-blue/src/interfaces/IMorpho.sol";

contract DeployMangroveUsdcWethLoopyVault is Script {
    // Base network addresses
    address constant USDC_BASE = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;
    address constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    address constant WST_ETH_BASE = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant AAVE_POOL_BASE = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_ORACLE_ADDRESS = 0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156;
    address constant MORPHO_BASE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant AERODROME_FACTORY_BASE = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address constant AERODROME_ROUTER_BASE = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant AERODROME_WETH_ST_ETH_POOL_BASE = 0xA6385c73961dd9C58db2EF0c4EB98cE4B60651e8;
    address constant ETH_USD_PRICE_FEED_BASE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant WSTETH_ETH_PRICE_FEED_BASE = 0x43a5C292A453A3bF3606fa856197f09D7B74251a;
    bytes32 constant MORPHO_ST_ETH_WETH_MARKET_ID_BASE =
        0x3a4048c64ba1b375330d376b1ce40e4047d03b47ab4d48af484edec9fec801ba;

    // Configuration parameters
    uint256 constant INITIAL_TIMELOCK = 1 days;
    uint256 constant MAX_ITERATIONS = 30;
    uint256 constant TARGET_LEVERAGE = 25_000; // 2.5x leverage (250% of initial capital)
    uint256 constant MORPHO_LTV = 9000; // 90% LTV for Morpho borrowing
    uint256 constant AAVE_LTV = 5000; // 50% LTV for Aave borrowing
    string constant VAULT_NAME = "Mangrove USDC-WETH-Lido Loopy Vault";
    string constant VAULT_SYMBOL = "mgvUWLV";

    function run() public {
        console.log("Deploying with wallet:", msg.sender);
        vm.startBroadcast();
        address owner = vm.envAddress("OWNER_ADDRESS");

        address curator = vm.envAddress("CURATOR_ADDRESS");
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        address allocator = vm.envAddress("ALLOCATOR_ADDRESS");

        // Deploy swapper
        AerodromeSwapper swapper = new AerodromeSwapper(AERODROME_FACTORY_BASE, AERODROME_ROUTER_BASE);

        // Get ghostbook
        IMangroveGhostbook ghostbook = IMangroveGhostbook(vm.envAddress("GHOSTBOOK_ADDRESS_BASE"));

        // Set up morpho borrow params
        MarketParams memory morphoBorrowParams = MarketParams({
            loanToken: WETH_BASE,
            collateralToken: WST_ETH_BASE,
            oracle: 0x4A11590e5326138B514E08A9B52202D42077Ca65,
            irm: 0x46415998764C29aB2a25CbeA6254146D50D22687,
            lltv: 945_000_000_000_000_000
        });

        // Create vault params
        MangroveUsdcWethLidoLoopyVault.VaultParams memory params = MangroveUsdcWethLidoLoopyVault.VaultParams({
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
            wstEthEthPriceFeed: WSTETH_ETH_PRICE_FEED_BASE,
            maxPriceStaleness: 24 hours,
            curator: curator,
            guardian: guardian,
            feeRecipient: feeRecipient,
            allocator: allocator,
            fee: 0.1 ether,
            autoExecuteOnDeposit: true
        });

        // Deploy vault
        MangroveUsdcWethLidoLoopyVault vault = new MangroveUsdcWethLidoLoopyVault(params);

        vm.stopBroadcast();

        console.log("Deployed Vault at:", address(vault));
        console.log("Deployed Swapper at:", address(swapper));
    }
}
