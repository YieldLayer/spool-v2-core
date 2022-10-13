// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

error InvalidStrategy(address address_);
error StrategyAlreadyRegistered(address address_);

interface IStrategyRegistry {
    function isStrategy(address strategy) external view returns (bool);
    function registerStrategy(address strategy) external;
    function removeStrategy(address strategy) external;
    function strategyDeposits(address strategy, uint256 index) external returns (uint256[] memory);
    function currentIndex(address strategy) external view returns (uint256);
    function addDeposits(address[] memory strategies_, uint256[][] memory amounts, address[] memory tokens)
        external
        returns (uint256[] memory);
}
