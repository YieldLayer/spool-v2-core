// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.16;

import "../interfaces/IUsdPriceFeedManager.sol";
import "../interfaces/IMasterWallet.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IStrategyRegistry.sol";
import "@openzeppelin/token/ERC20/ERC20.sol";
import "@openzeppelin/utils/math/Math.sol";

/**
 * @title Spool utility functions.
 * @notice This library gathers various utility functions.
 */
library SpoolUtils {
    /**
     * @notice Gets asset ratios for strategies as recorded at their last DHW.
     * Asset ratios are ordered according to each strategies asset group.
     * @param strategies_ Addresses of strategies.
     * @param strategyRegistry_ Strategy registry.
     * @return strategyRatios Required asset ratio for strategies.
     */
    function getStrategyRatiosAtLastDhw(address[] memory strategies_, IStrategyRegistry strategyRegistry_)
        public
        view
        returns (uint256[][] memory)
    {
        uint256[][] memory strategyRatios = new uint256[][](strategies_.length);

        for (uint256 i = 0; i < strategies_.length; i++) {
            strategyRatios[i] = strategyRegistry_.assetRatioAtLastDhw(strategies_[i]);
        }

        return strategyRatios;
    }

    /**
     * @notice Gets USD exchange rates for tokens.
     * The exchange rate is represented as a USD price for one token.
     * @param tokens_ Addresses of tokens.
     * @param priceFeedManager_ USD price feed mananger.
     * @return exchangeRates Exchange rates for tokens.
     */
    function getExchangeRates(address[] memory tokens_, IUsdPriceFeedManager priceFeedManager_)
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory exchangeRates = new uint256[](tokens_.length);
        for (uint256 i = 0; i < tokens_.length; i++) {
            exchangeRates[i] =
                priceFeedManager_.assetToUsd(tokens_[i], 10 ** priceFeedManager_.assetDecimals(tokens_[i]));
        }

        return exchangeRates;
    }

    /**
     * @dev Gets revert message when a low-level call reverts, so that it can
     * be bubbled-up to caller.
     * @param returnData_ Data returned from reverted low-level call.
     * @return revertMsg Original revert message if available, or default message otherwise.
     */
    function getRevertMsg(bytes memory returnData_) public pure returns (string memory) {
        // if the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (returnData_.length < 68) {
            return "SmartVaultManager::_getRevertMsg: Transaction reverted silently.";
        }

        assembly {
            // slice the sig hash
            returnData_ := add(returnData_, 0x04)
        }

        return abi.decode(returnData_, (string)); // all that remains is the revert string
    }

    /**
     * @notice Gets total USD value of a smart vault.
     * @dev Should be called with addresses of all strategies used by the smart vault,
     * otherwise total USD value will be lower than it actually is.
     * @param smartVault_ Address of the smart vault.
     * @param strategyAddresses_ Addresses of smart vault's strategies.
     * @return totalUsdValue Total USD value of the smart vault.
     */
    function getVaultTotalUsdValue(address smartVault_, address[] memory strategyAddresses_)
        public
        view
        returns (uint256)
    {
        return getVaultTotalUsdValue(smartVault_, strategyAddresses_, new uint256[](strategyAddresses_.length));
    }

    /**
     * @notice Gets total USD value of a smart vault.
     * @dev Should be called with addresses of all strategies used by the smart vault,
     * otherwise total USD value will be lower than it actually is.
     * @param smartVault_ Address of the smart vault.
     * @param strategyAddresses_ Addresses of smart vault's strategies.
     * @param pendingShares shares that haven't been transferred yet
     * @return totalUsdValue Total USD value of the smart vault.
     */
    function getVaultTotalUsdValue(
        address smartVault_,
        address[] memory strategyAddresses_,
        uint256[] memory pendingShares
    ) public view returns (uint256) {
        uint256 totalUsdValue = 0;

        for (uint256 i = 0; i < strategyAddresses_.length; i++) {
            IStrategy strategy = IStrategy(strategyAddresses_[i]);
            uint256 shares = strategy.balanceOf(smartVault_) + pendingShares[i];
            totalUsdValue = totalUsdValue + strategy.totalUsdValue() * shares / strategy.totalSupply();
        }

        return totalUsdValue;
    }
}
