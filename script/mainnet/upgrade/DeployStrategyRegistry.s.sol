// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "../../../src/managers/StrategyRegistry.sol";
import "../MainnetExtendedSetup.s.sol";

contract DeployStrategyRegistry is MainnetExtendedSetup {
    function broadcast() public override {
        _deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    }

    function execute() public override {
        vm.broadcast(_deployerPrivateKey);
        StrategyRegistry implementation = new StrategyRegistry(
            masterWallet,
            spoolAccessControl,
            usdPriceFeedManager,
            address(ghostStrategy)
        );

        _contractsJson.addProxy("StrategyRegistry", address(implementation), address(strategyRegistry));
    }
}
