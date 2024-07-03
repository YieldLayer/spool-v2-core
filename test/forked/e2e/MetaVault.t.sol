// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "../../../src/interfaces/Constants.sol";
import "../../../src/strategies/AaveV2Strategy.sol";
import "../../../src/strategies/CompoundV2Strategy.sol";
import "../../libraries/Arrays.sol";
import "../../libraries/Constants.sol";
import "../../fixtures/TestFixture.sol";
import "../../mocks/MockAllocationProvider.sol";
import "../ForkTestFixtureDeployment.sol";

import "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../src/MetaVault.sol";

contract MetaVaultTest is ForkTestFixtureDeployment {
    MockAllocationProvider public mockAllocationProvider;

    function setUp() public {
        _deploy(Extended.INITIAL); // deploy just initial strategies

        mockAllocationProvider = new MockAllocationProvider();
        vm.startPrank(_spoolAdmin);
        _deploySpool.spoolAccessControl().grantRole(ROLE_ALLOCATION_PROVIDER, address(mockAllocationProvider));
        vm.stopPrank();
    }

    function test_deploySpool() public {
        uint256 assetGroupIdUSDC = _getAssetGroupId(USDC_KEY);

        address aaveStrategy = _getStrategyAddress(AAVE_V2_KEY, assetGroupIdUSDC);
        address compoundV2Strategy = _getStrategyAddress(COMPOUND_V2_KEY, assetGroupIdUSDC);

        address[] memory strategies = Arrays.toArray(aaveStrategy, compoundV2Strategy);

        uint16a16 allocations = uint16a16Lib.set(uint16a16.wrap(0), Arrays.toArray(FULL_PERCENT / 2, FULL_PERCENT / 2));
        ISmartVault vault = _createVault(0, 0, assetGroupIdUSDC, strategies, allocations, address(0));

        address alice = address(0xa);
        _dealTokens(alice);

        // DEPOSIT
        uint256 depositAmount = 10 ** 10;
        uint256 depositId = _deposit(vault, alice, depositAmount);
        _flushVaults(vault);

        // DHW
        _dhw(strategies);

        // WITHDRAWAL
        uint256 withdrawalId = _redeemNfts(vault, alice, depositId);
        _flushVaults(vault);

        // DHW
        _dhw(strategies);

        // CLAIM
        uint256 balanceBefore = usdc.balanceOf(alice);
        _claimWithdrawals(vault, alice, withdrawalId);
        uint256 balanceAfter = usdc.balanceOf(alice);

        assertApproxEqAbs(balanceAfter - balanceBefore, depositAmount, 2);
    }

    function test_metaVault_simpleFlow() public {
        uint256 assetGroupIdUSDC = _getAssetGroupId(USDC_KEY);

        address strategy1 = _getStrategyAddress(AAVE_V2_KEY, assetGroupIdUSDC);
        address strategy2 = _getStrategyAddress(COMPOUND_V2_KEY, assetGroupIdUSDC);
        address[] memory strategies = new address[](2);
        strategies[0] = strategy1;
        strategies[1] = strategy2;

        uint16a16 allocations = uint16a16Lib.set(uint16a16.wrap(0), Arrays.toArray(FULL_PERCENT));
        ISmartVault vault1 = _createVault(assetGroupIdUSDC, Arrays.toArray(strategy1), allocations, address(0));
        ISmartVault vault2 = _createVault(assetGroupIdUSDC, Arrays.toArray(strategy2), allocations, address(0));

        ISmartVault[] memory vaults = new ISmartVault[](2);
        vaults[0] = vault1;
        vaults[1] = vault2;

        address owner = address(0x19);
        address user1 = address(0x1);
        _dealTokens(user1);
        _dealTokens(owner);

        vm.startPrank(owner);
        address metaVaultImpl = address(new MetaVault(address(_smartVaultManager), address(usdc)));
        MetaVault metaVault = MetaVault(address(new ERC1967Proxy(metaVaultImpl, "")));
        metaVault.initialize("MetaVault", "M");
        vm.stopPrank();

        vm.startPrank(user1);
        usdc.approve(address(metaVault), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(owner);
        usdc.approve(address(metaVault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user1);
        metaVault.deposit(100e6);
        assertEq(metaVault.balanceOf(user1), 100e6);
        assertEq(metaVault.availableAssets(), 100e6);
        assertEq(usdc.balanceOf(address(metaVault)), 100e6);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert(MetaVault.UnsupportedSmartVault.selector);
        metaVault.spoolDeposit(address(vault1), 80e6, true);
        {
            address[] memory v = new address[](2);
            v[0] = address(vault1);
            v[1] = address(vault2);
            metaVault.addSmartVaults(v);
            assertEq(metaVault.getSmartVaults(), v);
        }
        assertEq(metaVault.depositedSharesTotal(), 0);
        metaVault.spoolDeposit(address(vault1), 60e6, true);
        assertEq(metaVault.availableAssets(), 40e6);
        assertEq(usdc.balanceOf(address(metaVault)), 40e6);
        assertEq(metaVault.depositedSharesTotal(), 60e6);
        metaVault.spoolDeposit(address(vault2), 20e6, true);
        assertEq(metaVault.availableAssets(), 20e6);
        assertEq(usdc.balanceOf(address(metaVault)), 20e6);
        assertEq(metaVault.depositedSharesTotal(), 80e6);
        vm.stopPrank();

        _dhw(strategies);
        {
            vm.startPrank(user1);
            metaVault.redeemRequest(20e6);
            uint256 currentWithdrawalIndex = metaVault.currentWithdrawalIndex();
            uint256 totalRequested = metaVault.withdrawalIndexToRedeemedShares(currentWithdrawalIndex);
            uint256 userRequested = metaVault.userToWithdrawalIndexToRedeemedShares(user1, currentWithdrawalIndex);
            assertEq(20e6, userRequested);
            assertEq(totalRequested, userRequested);
            assertEq(metaVault.availableAssets(), 20e6);
            assertEq(metaVault.balanceOf(user1), 80e6);
            vm.expectRevert(MetaVault.RedeemRequestNotFulfilled.selector);
            // user cannot withdraw if request is not fulfilled
            metaVault.withdraw(currentWithdrawalIndex);
            vm.stopPrank();
            vm.startPrank(owner);
            // owner cannot deposit if there is pending redeem request
            vm.expectRevert(MetaVault.PendingRedeemRequests.selector);
            metaVault.spoolDeposit(address(vault1), 20e6, true);
            vm.stopPrank();
        }

        vm.startPrank(owner);
        vm.expectRevert(MetaVault.PendingDeposits.selector);
        metaVault.initiateWithdrawal();
        uint256 withdrawalIndex = metaVault.currentWithdrawalIndex();
        metaVault.spoolClaimSmartVaultTokens(address(vault1), metaVault.getSmartVaultDepositNftIds(address(vault1)));
        metaVault.spoolClaimSmartVaultTokens(address(vault2), metaVault.getSmartVaultDepositNftIds(address(vault2)));
        uint256 svts1Before = vault1.balanceOf(address(metaVault));
        uint256 svts2Before = vault2.balanceOf(address(metaVault));
        metaVault.initiateWithdrawal();
        assertEq(withdrawalIndex + 1, metaVault.currentWithdrawalIndex());
        vm.stopPrank();
        assertEq(metaVault.getSmartVaultWithdrawalNftIds(address(vault1)).length, 1);
        assertEq(metaVault.getSmartVaultWithdrawalNftIds(address(vault2)).length, 1);

        _flushVaults(vaults);
        _dhw(strategies);

        {
            vm.startPrank(owner);
            uint256 lastFulfilledWithdrawalIndex = metaVault.lastFulfilledWithdrawalIndex();
            metaVault.finalizeWithdrawal();
            uint256 svts1Withdrawn = svts1Before - vault1.balanceOf(address(metaVault));
            uint256 svts2Withdrawn = svts2Before - vault2.balanceOf(address(metaVault));
            assertEq(svts1Withdrawn * 100 / svts1Before, svts2Withdrawn * 100 / svts2Before);
            assertEq(svts1Withdrawn * 100 / svts1Before, 20 * 100 / 80);

            assertEq(lastFulfilledWithdrawalIndex + 1, metaVault.lastFulfilledWithdrawalIndex());
            assertEq(metaVault.depositedSharesTotal(), 60e6);
            assertEq(metaVault.getSmartVaultWithdrawalNftIds(address(vault1)).length, 0);
            assertEq(metaVault.getSmartVaultWithdrawalNftIds(address(vault2)).length, 0);
            vm.stopPrank();
        }

        {
            vm.startPrank(user1);
            uint256 userBalanceBefore = usdc.balanceOf(user1);
            metaVault.withdraw(1);
            uint256 userBalanceAfter = usdc.balanceOf(user1);
            assertApproxEqAbs(userBalanceAfter - userBalanceBefore, 20e6, 2);
            assertEq(userBalanceAfter - userBalanceBefore, metaVault.withdrawalIndexToWithdrawnAssets(1));
            vm.stopPrank();
        }
    }

    function _createVault(
        uint256 assetGroupId,
        address[] memory strategies,
        uint16a16 allocations,
        address allocationProvider
    ) internal returns (ISmartVault smartVault) {
        address riskProvider = _riskProvider;

        if (uint16a16.unwrap(allocations) > 0) {
            riskProvider = address(0);
        }

        smartVault = _deploySpool.smartVaultFactory().deploySmartVault(
            SmartVaultSpecification({
                smartVaultName: "MySmartVault",
                svtSymbol: "MSV",
                baseURI: "https://token-cdn-domain/",
                assetGroupId: assetGroupId,
                actions: new IAction[](0),
                actionRequestTypes: new RequestType[](0),
                guards: new GuardDefinition[][](0),
                guardRequestTypes: new RequestType[](0),
                strategies: strategies,
                strategyAllocation: allocations,
                riskTolerance: 0,
                riskProvider: riskProvider,
                managementFeePct: 0,
                depositFeePct: 0,
                allocationProvider: allocationProvider,
                performanceFeePct: 100,
                allowRedeemFor: false
            })
        );
    }
}
