// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.16;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "../../src/managers/ActionManager.sol";
import "../../src/managers/AssetGroupRegistry.sol";
import "../../src/managers/GuardManager.sol";
import "../../src/managers/RiskManager.sol";
import "../../src/managers/SmartVaultManager.sol";
import "../../src/managers/StrategyRegistry.sol";
import "../../src/managers/UsdPriceFeedManager.sol";
import "../../src/MasterWallet.sol";
import "../../src/SmartVault.sol";
import "../../src/SmartVaultFactory.sol";
import "../../src/Swapper.sol";
import "../libraries/Arrays.sol";
import "../libraries/Constants.sol";
import "../mocks/MockStrategy.sol";
import "../mocks/MockToken.sol";
import "../mocks/MockPriceFeedManager.sol";
import "../fixtures/TestFixture.sol";

contract IntegrationTestFixture is TestFixture {
    address internal alice;

    MockToken internal tokenA;
    MockToken internal tokenB;
    MockToken internal tokenC;

    MockStrategy internal strategyA;
    MockStrategy internal strategyB;
    MockStrategy internal strategyC;
    address[] internal smartVaultStrategies;
    address[] internal assetGroup;
    uint256 internal assetGroupId;

    function setUpBase() public override {
        super.setUpBase();
        alice = address(0xa);

        tokenA = new MockToken("Token A", "TA");
        tokenB = new MockToken("Token B", "TB");
        tokenC = new MockToken("Token C", "TC");

        // set initial state
        deal(address(tokenA), alice, 100 ether, true);
        deal(address(tokenB), alice, 10 ether, true);
        deal(address(tokenC), alice, 500 ether, true);

        assetGroup = Arrays.toArray(address(tokenA), address(tokenB), address(tokenC));
        assetGroupRegistry.allowTokenBatch(assetGroup);
        assetGroupId = assetGroupRegistry.registerAssetGroup(assetGroup);
        uint256[] memory strategyRatios = Arrays.toArray(1000, 71, 4300);
        strategyA = new MockStrategy("StratA", strategyRegistry, assetGroupRegistry, accessControl, swapper);
        strategyA.initialize(assetGroupId, strategyRatios);
        strategyRegistry.registerStrategy(address(strategyA));

        strategyRatios = Arrays.toArray(1000, 74, 4500);
        strategyB = new MockStrategy("StratB", strategyRegistry, assetGroupRegistry, accessControl, swapper);
        strategyB.initialize(assetGroupId, strategyRatios);
        strategyRegistry.registerStrategy(address(strategyB));

        strategyRatios = Arrays.toArray(1000, 76, 4600);
        strategyC = new MockStrategy("StratC", strategyRegistry, assetGroupRegistry, accessControl, swapper);
        strategyC.initialize(assetGroupId, strategyRatios);
        strategyRegistry.registerStrategy(address(strategyC));

        accessControl.grantRole(ROLE_RISK_PROVIDER, riskProvider);
        accessControl.grantRole(ROLE_STRATEGY_CLAIMER, address(smartVaultManager));
        accessControl.grantRole(ROLE_MASTER_WALLET_MANAGER, address(strategyRegistry));

        priceFeedManager.setExchangeRate(address(tokenA), 1200 * USD_DECIMALS_MULTIPLIER);
        priceFeedManager.setExchangeRate(address(tokenB), 16400 * USD_DECIMALS_MULTIPLIER);
        priceFeedManager.setExchangeRate(address(tokenC), 270 * USD_DECIMALS_MULTIPLIER);
    }

    function createVault() internal {
        createVault(0, 0);
    }

    function createVault(uint256 managementFeePct, uint256 depositFeePct) internal {
        address smartVaultImplementation = address(new SmartVault(accessControl, guardManager));
        SmartVaultFactory smartVaultFactory = new SmartVaultFactory(
            smartVaultImplementation,
            accessControl,
            actionManager,
            guardManager,
            smartVaultManager,
            assetGroupRegistry
        );
        accessControl.grantRole(ROLE_SMART_VAULT_INTEGRATOR, address(smartVaultFactory));

        smartVaultStrategies = Arrays.toArray(address(strategyA), address(strategyB), address(strategyC));

        vm.mockCall(
            address(riskManager),
            abi.encodeWithSelector(IRiskManager.calculateAllocation.selector),
            abi.encode(Arrays.toArray(600, 300, 100))
        );

        smartVault = smartVaultFactory.deploySmartVault(
            SmartVaultSpecification({
                smartVaultName: "MySmartVault",
                assetGroupId: assetGroupId,
                actions: new IAction[](0),
                actionRequestTypes: new RequestType[](0),
                guards: new GuardDefinition[][](0),
                guardRequestTypes: new RequestType[](0),
                strategies: smartVaultStrategies,
                riskAppetite: 4,
                riskProvider: riskProvider,
                managementFeePct: managementFeePct,
                depositFeePct: depositFeePct
            })
        );
    }
}