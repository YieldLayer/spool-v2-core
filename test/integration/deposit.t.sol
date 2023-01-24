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
import "../mocks/TestFixture.sol";

contract DepositIntegrationTest is TestFixture {
    address private alice;

    MockToken tokenA;
    MockToken tokenB;
    MockToken tokenC;

    MockStrategy strategyA;
    MockStrategy strategyB;
    MockStrategy strategyC;
    address[] smartVaultStrategies;

    function setUp() public {
        setUpBase();
        alice = address(0xa);

        tokenA = new MockToken("Token A", "TA");
        tokenB = new MockToken("Token B", "TB");
        tokenC = new MockToken("Token C", "TC");

        address[] memory assetGroup = Arrays.toArray(address(tokenA), address(tokenB), address(tokenC));
        assetGroupRegistry.allowToken(address(tokenA));
        assetGroupRegistry.allowToken(address(tokenB));
        assetGroupRegistry.allowToken(address(tokenC));

        uint256 assetGroupId = assetGroupRegistry.registerAssetGroup(assetGroup);

        strategyA = new MockStrategy("StratA", strategyRegistry, assetGroupRegistry, accessControl, new Swapper());
        uint256[] memory strategyRatios = new uint256[](3);
        strategyRatios[0] = 1000;
        strategyRatios[1] = 71;
        strategyRatios[2] = 4300;
        strategyA.initialize(assetGroupId, strategyRatios);
        strategyRegistry.registerStrategy(address(strategyA));

        strategyRatios[1] = 74;
        strategyRatios[2] = 4500;
        strategyB = new MockStrategy("StratB", strategyRegistry, assetGroupRegistry, accessControl, new Swapper());
        strategyB.initialize(assetGroupId, strategyRatios);
        strategyRegistry.registerStrategy(address(strategyB));

        strategyRatios[1] = 76;
        strategyRatios[2] = 4600;
        strategyC = new MockStrategy("StratC", strategyRegistry, assetGroupRegistry, accessControl, new Swapper());
        strategyC.initialize(assetGroupId, strategyRatios);
        strategyRegistry.registerStrategy(address(strategyC));

        accessControl.grantRole(ROLE_RISK_PROVIDER, riskProvider);
        accessControl.grantRole(ROLE_STRATEGY_CLAIMER, address(smartVaultManager));
        accessControl.grantRole(ROLE_MASTER_WALLET_MANAGER, address(strategyRegistry));

        {
            address smartVaultImplementation = address(new SmartVault(accessControl, guardManager));
            SmartVaultFactory smartVaultFactory = new SmartVaultFactory(
                smartVaultImplementation,
                accessControl,
                actionManager,
                guardManager,
                smartVaultManager,
                assetGroupRegistry
            );
            accessControl.grantRole(ADMIN_ROLE_SMART_VAULT, address(smartVaultFactory));
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
                    riskProvider: riskProvider
                })
            );
        }

        priceFeedManager.setExchangeRate(address(tokenA), 1200 * USD_DECIMALS_MULTIPLIER);
        priceFeedManager.setExchangeRate(address(tokenB), 16400 * USD_DECIMALS_MULTIPLIER);
        priceFeedManager.setExchangeRate(address(tokenC), 270 * USD_DECIMALS_MULTIPLIER);
    }

    function test_shouldBeAbleToDeposit() public {
        bytes32 a = accessControl.getRoleAdmin(ROLE_SMART_VAULT);
        console.logBytes32(a);
        // set initial state
        deal(address(tokenA), alice, 100 ether, true);
        deal(address(tokenB), alice, 10 ether, true);
        deal(address(tokenC), alice, 500 ether, true);

        // Alice deposits
        vm.startPrank(alice);

        uint256[] memory depositAmounts = Arrays.toArray(100 ether, 7.237 ether, 438.8 ether);

        tokenA.approve(address(smartVaultManager), depositAmounts[0]);
        tokenB.approve(address(smartVaultManager), depositAmounts[1]);
        tokenC.approve(address(smartVaultManager), depositAmounts[2]);

        uint256 aliceDepositNftId =
            smartVaultManager.deposit(DepositBag(address(smartVault), depositAmounts, alice, address(0)));

        vm.stopPrank();

        // check state
        // - tokens were transferred
        assertEq(tokenA.balanceOf(alice), 0 ether);
        assertEq(tokenB.balanceOf(alice), 2.763 ether);
        assertEq(tokenC.balanceOf(alice), 61.2 ether);
        assertEq(tokenA.balanceOf(address(masterWallet)), 100 ether);
        assertEq(tokenB.balanceOf(address(masterWallet)), 7.237 ether);
        assertEq(tokenC.balanceOf(address(masterWallet)), 438.8 ether);
        // - deposit NFT was minted
        assertEq(aliceDepositNftId, 1);
        assertEq(smartVault.balanceOfFractional(alice, aliceDepositNftId), NFT_MINTED_SHARES);

        // flush
        smartVaultManager.flushSmartVault(address(smartVault));

        // DHW
        SwapInfo[][] memory dhwSwapInfo = new SwapInfo[][](3);
        dhwSwapInfo[0] = new SwapInfo[](0);
        dhwSwapInfo[1] = new SwapInfo[](0);
        dhwSwapInfo[2] = new SwapInfo[](0);

        strategyRegistry.doHardWork(smartVaultStrategies, dhwSwapInfo);

        // check state
        // - tokens were routed to the protocol
        assertEq(tokenA.balanceOf(address(strategyA.protocol())), 60_787285104601546518);
        assertEq(tokenB.balanceOf(address(strategyA.protocol())), 4_315894186899635873);
        assertEq(tokenC.balanceOf(address(strategyA.protocol())), 261_378837986158860145);
        assertEq(tokenA.balanceOf(address(strategyB.protocol())), 29_529225446144834384);
        assertEq(tokenB.balanceOf(address(strategyB.protocol())), 2_185161135984433228);
        assertEq(tokenC.balanceOf(address(strategyB.protocol())), 132_878216195362039975);
        assertEq(tokenA.balanceOf(address(strategyC.protocol())), 9_683489449253619098);
        assertEq(tokenB.balanceOf(address(strategyC.protocol())), 735944677115930899);
        assertEq(tokenC.balanceOf(address(strategyC.protocol())), 44_542945818479099880);
        assertEq(tokenA.balanceOf(address(masterWallet)), 0);
        assertEq(tokenB.balanceOf(address(masterWallet)), 0);
        assertEq(tokenC.balanceOf(address(masterWallet)), 0);
        // - strategy tokens were minted
        assertEq(strategyA.totalSupply(), 214297693046938776377950000);
        assertEq(strategyB.totalSupply(), 107148831538266256993250000);
        assertEq(strategyC.totalSupply(), 35716275414794966628800000);

        // sync vault
        smartVaultManager.syncSmartVault(address(smartVault));

        // check state
        // - strategy tokens were claimed
        assertEq(strategyA.balanceOf(address(smartVault)), 214297693046938776377950000);
        assertEq(strategyB.balanceOf(address(smartVault)), 107148831538266256993250000);
        assertEq(strategyC.balanceOf(address(smartVault)), 35716275414794966628800000);
        assertEq(strategyA.balanceOf(address(strategyA)), 0);
        assertEq(strategyB.balanceOf(address(strategyB)), 0);
        assertEq(strategyB.balanceOf(address(strategyB)), 0);
        // - vault tokens were minted
        assertEq(smartVault.totalSupply(), 357162800000000000000000000);
        assertEq(smartVault.balanceOf(address(smartVault)), 357162800000000000000000000);

        uint256 balance = smartVaultManager.getUserSVTBalance(address(smartVault), alice);
        assertEq(balance, 357162800000000000000000000);

        // claim deposit
        uint256[] memory amounts = Arrays.toArray(NFT_MINTED_SHARES);
        uint256[] memory ids = Arrays.toArray(aliceDepositNftId);
        vm.prank(alice);
        smartVaultManager.claimSmartVaultTokens(address(smartVault), ids, amounts);

        // check state
        // - vault tokens were claimed
        assertEq(smartVault.balanceOf(address(alice)), 357162800000000000000000000);
        assertEq(smartVault.balanceOf(address(smartVault)), 0);
        // - deposit NFT was burned
        assertEq(smartVault.balanceOfFractional(alice, aliceDepositNftId), 0);
    }

    function test_claimSmartVaultTokensPartially() public {
        bytes32 a = accessControl.getRoleAdmin(ROLE_SMART_VAULT);
        console.logBytes32(a);
        // set initial state
        deal(address(tokenA), alice, 100 ether, true);
        deal(address(tokenB), alice, 10 ether, true);
        deal(address(tokenC), alice, 500 ether, true);

        // Alice deposits
        vm.startPrank(alice);

        uint256[] memory depositAmounts = Arrays.toArray(100 ether, 7.237 ether, 438.8 ether);

        tokenA.approve(address(smartVaultManager), depositAmounts[0]);
        tokenB.approve(address(smartVaultManager), depositAmounts[1]);
        tokenC.approve(address(smartVaultManager), depositAmounts[2]);

        uint256 aliceDepositNftId =
            smartVaultManager.deposit(DepositBag(address(smartVault), depositAmounts, alice, address(0)));

        vm.stopPrank();

        // flush
        smartVaultManager.flushSmartVault(address(smartVault));

        // DHW
        SwapInfo[][] memory dhwSwapInfo = new SwapInfo[][](3);
        dhwSwapInfo[0] = new SwapInfo[](0);
        dhwSwapInfo[1] = new SwapInfo[](0);
        dhwSwapInfo[2] = new SwapInfo[](0);

        strategyRegistry.doHardWork(smartVaultStrategies, dhwSwapInfo);

        // sync vault
        smartVaultManager.syncSmartVault(address(smartVault));

        uint256 svtBalance = 357162800000000000000000000;

        // - vault tokens were minted
        assertEq(smartVault.totalSupply(), svtBalance);
        assertEq(smartVault.balanceOf(address(smartVault)), svtBalance);

        uint256 balance = smartVaultManager.getUserSVTBalance(address(smartVault), alice);
        assertEq(balance, svtBalance);

        // burn half of NFT
        uint256[] memory amounts = Arrays.toArray(NFT_MINTED_SHARES / 2);
        uint256[] memory ids = Arrays.toArray(aliceDepositNftId);
        vm.startPrank(alice);
        smartVaultManager.claimSmartVaultTokens(address(smartVault), ids, amounts);

        // check state
        // - vault tokens were partially claimed
        assertEq(smartVault.balanceOf(address(alice)), svtBalance / 2);
        assertEq(smartVault.balanceOf(address(smartVault)), svtBalance / 2);

        // - deposit NFT was partially burned
        assertEq(smartVault.balanceOfFractional(alice, aliceDepositNftId), NFT_MINTED_SHARES / 2);

        // burn remaining of NFT
        smartVaultManager.claimSmartVaultTokens(address(smartVault), ids, amounts);

        // check state
        // - vault tokens were claimed in full
        assertEq(smartVault.balanceOf(address(alice)), svtBalance);
        assertEq(smartVault.balanceOf(address(smartVault)), 0);

        // - deposit NFT was burned in full
        assertEq(smartVault.balanceOfFractional(alice, aliceDepositNftId), 0);
    }
}
