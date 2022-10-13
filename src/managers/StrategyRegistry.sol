// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.16;

import "../interfaces/IStrategy.sol";
import "../interfaces/IStrategyRegistry.sol";
import "../interfaces/IUsdPriceFeedManager.sol";

contract StrategyRegistry is IStrategyRegistry {
    /* ========== STATE VARIABLES ========== */

    /// @notice TODO
    mapping(address => bool) internal _strategies;

    /// @notice TODO
    mapping(address => uint256) _currentIndexes;

    /// @notice TODO strategy => index => tokenAmounts
    mapping(address => mapping(uint256 => uint256[])) _strategyDeposits;

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice TODO
     */
    function isStrategy(address strategy) external view returns (bool) {
        return _strategies[strategy];
    }

    /**
     * @notice Deposits for given strategy and DHW index
     */
    function strategyDeposits(address strategy, uint256 index) external returns (uint256[] memory) {
        return _strategyDeposits[strategy][index];
    }

    /**
     * @notice Deposits for given strategy and DHW index
     */
    function currentIndex(address strategy) external view returns (uint256) {
        return _currentIndexes[strategy];
    }

    /* ========== EXTERNAL MUTATIVE FUNCTIONS ========== */

    /**
     * @notice TODO
     */
    function registerStrategy(address strategy) external {
        if (_strategies[strategy]) revert StrategyAlreadyRegistered({address_: strategy});
        _strategies[strategy] = true;
    }

    /**
     * @notice TODO
     */
    function removeStrategy(address strategy) external {
        if (!_strategies[strategy]) revert InvalidStrategy({address_: strategy});
        _strategies[strategy] = false;
    }

    function addDeposits(address[] memory strategies_, uint256[][] memory amounts, address[] memory tokens)
        external
        returns (uint256[] memory)
    {
        uint256[] memory indexes = new uint256[](strategies_.length);
        for (uint256 i = 0; i < strategies_.length; i++) {
            address strategy = strategies_[i];
            uint256 latestIndex = _currentIndexes[strategy];
            indexes[i] = latestIndex;
            bool initialized = _strategyDeposits[strategy][latestIndex].length > 0;

            for (uint256 j = 0; j < amounts[i].length; j++) {
                if (initialized) {
                    _strategyDeposits[strategy][latestIndex][j] += amounts[i][j];
                } else {
                    _strategyDeposits[strategy][latestIndex].push(amounts[i][j]);
                }
            }
        }

        return indexes;
    }
}
