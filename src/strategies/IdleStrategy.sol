// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "@openzeppelin/token/ERC20/IERC20.sol";
import "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "../external/interfaces/strategies/idle/IIdleToken.sol";
import "./Strategy.sol";

error IdleBeforeDepositCheckFailed();
error IdleBeforeRedeemalCheckFailed();
error IdleDepositSlippagesFailed();
error IdleRedeemSlippagesFailed();

// only uses one asset
// slippages
// - mode selection: slippages[0]
// - DHW with deposit: slippages[0] == 0
//   - beforeDepositCheck: slippages[1..2]
//   - beforeRedeemalCheck: slippages[3..4]
//   - compound: slippages[5]
//   - _depositToProtocol: slippages[6]
// - DHW with withdrawal: slippages[0] == 1
//   - beforeDepositCheck: slippages[1..2]
//   - beforeRedeemalCheck: slippages[3..4]
//   - compound: slippages[5]
//   - _redeemFromProtocol: slippages[6]
// - reallocate: slippages[0] == 2
//   - beforeDepositCheck: depositSlippages[1..2]
//   - _depositToProtocol: depositSlippages[3]
//   - beforeRedeemalCheck: withdrawalSlippages[1..2]
//   - _redeemFromProtocol: withdrawalSlippages[3]
// - redeemFast or emergencyWithdraw: slippages[0] == 3
//   - _redeemFromProtocol or _emergencyWithdrawImpl: slippages[1]
contract IdleStrategy is Strategy {
    using SafeERC20 for IERC20;

    ISwapper public immutable swapper;

    IIdleToken public immutable idleToken;

    uint256 public immutable oneShare;

    uint256 private _lastIdleTokenPrice;

    constructor(
        IAssetGroupRegistry assetGroupRegistry_,
        ISpoolAccessControl accessControl_,
        uint256 assetGroupId_,
        ISwapper swapper_,
        IIdleToken idleToken_
    ) Strategy(assetGroupRegistry_, accessControl_, assetGroupId_) {
        if (address(idleToken_) == address(0)) {
            revert ConfigurationAddressZero();
        }

        swapper = swapper_;

        idleToken = idleToken_;
        oneShare = 10 ** idleToken_.decimals();
    }

    function initialize(string memory strategyName_) external initializer {
        __Strategy_init(strategyName_);

        address[] memory tokens = _assetGroupRegistry.listAssetGroup(_assetGroupId);

        if (tokens.length != 1 || tokens[0] != idleToken.token()) {
            revert InvalidAssetGroup(_assetGroupId);
        }

        _lastIdleTokenPrice = idleToken.tokenPriceWithFee(address(this));
    }

    function assetRatio() external pure override returns (uint256[] memory) {
        uint256[] memory _assetRatio = new uint256[](1);
        _assetRatio[0] = 1;
        return _assetRatio;
    }

    function beforeDepositCheck(uint256[] memory amounts, uint256[] calldata slippages) public pure override {
        if (amounts[0] < slippages[1] || amounts[1] > slippages[2]) {
            revert IdleBeforeDepositCheckFailed();
        }
    }

    function beforeRedeemalCheck(uint256 ssts, uint256[] calldata slippages) public pure override {
        if (
            (slippages[0] < 2 && (ssts < slippages[3] || ssts > slippages[4]))
                || (ssts < slippages[1] || ssts > slippages[2])
        ) {
            revert IdleBeforeRedeemalCheckFailed();
        }
    }

    function _depositToProtocol(address[] calldata tokens, uint256[] memory amounts, uint256[] calldata slippages)
        internal
        override
    {
        uint256 slippage;
        if (slippages[0] == 0) {
            slippage = slippages[6];
        } else if (slippages[0] == 2) {
            slippage = slippages[3];
        } else {
            revert IdleDepositSlippagesFailed();
        }

        _depositToIdle(tokens[0], amounts[0], slippage);
    }

    function _redeemFromProtocol(address[] calldata, uint256 ssts, uint256[] calldata slippages) internal override {
        uint256 idleTokensToRedeem = idleToken.balanceOf(address(this)) * ssts / totalSupply();
        uint256 slippage;

        if (slippages[0] == 1) {
            slippage = slippages[6];
        } else if (slippages[0] == 2) {
            slippage = slippages[2];
        } else if (slippages[0] == 3) {
            slippage = slippages[3];
        } else {
            revert IdleRedeemSlippagesFailed();
        }

        _redeemFromIdle(idleTokensToRedeem, slippage);
    }

    function _emergencyWithdrawImpl(uint256[] calldata slippages, address recipient) internal override {
        uint256 assetsWithdrawn = _redeemFromIdle(idleToken.balanceOf((address(this))), slippages[1]);

        address[] memory tokens = _assetGroupRegistry.listAssetGroup(_assetGroupId);

        IERC20(tokens[0]).safeTransfer(recipient, assetsWithdrawn);
    }

    function _compound(address[] calldata tokens, SwapInfo[] calldata compoundSwapInfo, uint256[] calldata slippages)
        internal
        override
        returns (int256 compoundYield)
    {
        if (compoundSwapInfo.length == 0) {
            return compoundYield;
        }

        address[] memory govTokens = idleToken.getGovTokens();
        idleToken.redeemIdleToken(0);

        for (uint256 i; i < govTokens.length; ++i) {
            uint256 balance = IERC20(govTokens[i]).balanceOf(address(this));

            if (balance > 0) {
                IERC20(govTokens[i]).safeTransfer(address(swapper), balance);
            }
        }

        uint256 swappedAmount = swapper.swap(govTokens, compoundSwapInfo, tokens, address(this))[0];

        uint256 idleTokensBefore = idleToken.balanceOf(address(this));

        uint256 idleTokensMinted = _depositToIdle(tokens[0], swappedAmount, slippages[5]);

        compoundYield = int256(YIELD_FULL_PERCENT * idleTokensMinted / idleTokensBefore);
    }

    function _getYieldPercentage(int256) internal override returns (int256 baseYieldPercentage) {
        uint256 currentIdleTokenPrice = idleToken.tokenPriceWithFee(address(this));

        baseYieldPercentage = _calculateYieldPercentage(_lastIdleTokenPrice, currentIdleTokenPrice);

        _lastIdleTokenPrice = currentIdleTokenPrice;
    }

    function _swapAssets(address[] memory tokens, uint256[] memory toSwap, SwapInfo[] calldata swapInfo)
        internal
        override
    {}

    function _getUsdWorth(uint256[] memory exchangeRates, IUsdPriceFeedManager priceFeedManager)
        internal
        view
        override
        returns (uint256)
    {
        uint256 assetWorth = idleToken.tokenPriceWithFee(address(this)) * idleToken.balanceOf(address(this)) / oneShare;
        address[] memory tokens = _assetGroupRegistry.listAssetGroup(_assetGroupId);

        return priceFeedManager.assetToUsdCustomPrice(tokens[0], assetWorth, exchangeRates[0]);
    }

    function _depositToIdle(address token, uint256 amount, uint256 slippage) private returns (uint256) {
        _resetAndApprove(IERC20(token), address(idleToken), amount);

        uint256 mintedIdleTokens = idleToken.mintIdleToken(
            amount,
            true, // not used by the protocol, can be anything
            address(this)
        );

        if (mintedIdleTokens < slippage) {
            revert IdleDepositSlippagesFailed();
        }

        return mintedIdleTokens;
    }

    function _redeemFromIdle(uint256 idleTokens, uint256 slippage) private returns (uint256) {
        uint256 redeemedAssets = idleToken.redeemIdleToken(idleTokens);

        if (redeemedAssets < slippage) {
            revert IdleRedeemSlippagesFailed();
        }

        return redeemedAssets;
    }
}
