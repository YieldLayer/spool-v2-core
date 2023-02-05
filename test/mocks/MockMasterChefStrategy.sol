// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.16;

import "@openzeppelin/token/ERC20/IERC20.sol";
import "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/utils/math/Math.sol";
import "../../src/Strategy.sol";
import "./MockMasterChef.sol";

contract MockMasterChefStrategy is Strategy {
    using SafeERC20 for IERC20;

    MockMasterChef public masterChef;
    uint256 public pid;

    constructor(
        string memory name_,
        IStrategyRegistry strategyRegistry_,
        IAssetGroupRegistry assetGroupRegistry_,
        ISpoolAccessControl accessControl_,
        MockMasterChef masterChef_,
        uint256 pid_
    ) Strategy(name_, strategyRegistry_, assetGroupRegistry_, accessControl_) {
        masterChef = masterChef_;
        pid = pid_;
    }

    function test_mock() external pure {}

    function initialize(uint256 assetGroupId_) external initializer {
        __Strategy_init(assetGroupId_);
    }

    function getAPY() external pure override returns (uint16) {
        return 0;
    }

    // NOTE: looks weird
    function assetRatio() external pure override returns (uint256[] memory) {
        uint256[] memory _assetRatio = new uint256[](1);
        _assetRatio[0] = 1;
        return _assetRatio;
    }

    function swapAssets(address[] memory tokens, SwapInfo[] calldata swapInfo) internal override {}

    function compound() internal override {
        uint256 assetBalanceBefore = _getAssetBalanceBefore();
        // claims rewards
        masterChef.deposit(pid, 0);
        uint256 assetBalanceDiff = _getAssetBalanceDiff(assetBalanceBefore);

        // NOTE: as reward token is same as the deposit token, deposit the claimed amount
        address[] memory assetGroup = _assetGroupRegistry.listAssetGroup(_assetGroupId);
        IERC20(assetGroup[0]).safeApprove(address(masterChef), assetBalanceDiff);
        masterChef.deposit(pid, assetBalanceDiff);
    }

    function depositToProtocol(address[] memory tokens, uint256[] memory amounts) internal override {
        if (amounts[0] > 0) {
            IERC20(tokens[0]).safeApprove(address(masterChef), amounts[0]);
            masterChef.deposit(pid, amounts[0]);
        }
    }

    function getUsdWorth(uint256[] memory exchangeRates, IUsdPriceFeedManager priceFeedManager)
        internal
        view
        override
        returns (uint256)
    {
        address[] memory assetGroup = _assetGroupRegistry.listAssetGroup(_assetGroupId);
        (uint256 balance,) = masterChef.userInfo(pid, address(this));

        uint256 usdWorth = priceFeedManager.assetToUsdCustomPrice(assetGroup[0], balance, exchangeRates[0]);

        return usdWorth;
    }

    function redeemFromProtocol(address[] memory, uint256 ssts) internal override {
        if (ssts == 0) {
            return;
        }

        (uint256 balance,) = masterChef.userInfo(pid, address(this));

        uint256 toWithdraw = balance * ssts / totalSupply();

        masterChef.withdraw(pid, toWithdraw);
    }

    function _getAssetBalanceBefore() private view returns (uint256) {
        address[] memory assetGroup = _assetGroupRegistry.listAssetGroup(_assetGroupId);

        return IERC20(assetGroup[0]).balanceOf(address(this));
    }

    function _getAssetBalanceDiff(uint256 assetBalanceBefore) private view returns (uint256) {
        address[] memory assetGroup = _assetGroupRegistry.listAssetGroup(_assetGroupId);

        uint256 assetBalanceAfter = IERC20(assetGroup[0]).balanceOf(address(this));

        if (assetBalanceAfter >= assetBalanceBefore) {
            unchecked {
                return assetBalanceAfter - assetBalanceBefore;
            }
        } else {
            revert("MockMasterChefStrategy::_getAssetBalanceDiff: Balance after should be equal or higher");
        }
    }
}
