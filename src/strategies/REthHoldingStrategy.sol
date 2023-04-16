// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "@openzeppelin/token/ERC20/IERC20.sol";
import "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "../external/interfaces/strategies/rEth/IREthToken.sol";
import "../external/interfaces/strategies/rEth/IRocketSwapRouter.sol";
import "./Strategy.sol";
import "./WethHelper.sol";

error REthHoldingBeforeDepositCheckFailed();
error REthHoldingBeforeRedeemalCheckFailed();
error REthHoldingDepositSlippagesFailed();
error REthHoldingRedeemSlippagesFailed();

// one asset
// no rewards
// slippages
// - mode selection: slippages[0]
// - DHW with deposit: slippages[0] == 0
//   - beforeDepositCheck: slippages[1..2]
//   - beforeRedeemalCheck: slippages[3..4]
//   - _depositToProtocol: slippages[5..8]
// - DHW with withdrawal: slippages[0] == 1
//   - beforeDepositCheck: slippages[1..2]
//   - beforeRedeemalCheck: slippages[3..4]
//   - _redeemFromProtocol: slippages[5..8]
// - reallocate: slippages[0] == 2
//   - beforeDepositCheck: depositSlippages[1..2]
//   - _depositToProtocol: depositSlippages[3..6]
//   - beforeRedeemalCheck: withdrawalSlippages[1..2]
//   - _redeemFromProtocol: withdrawalSlippages[3..6]
// - redeemFast or emergencyWithdraw: slippages[0] == 3
//   - _redeemFromProtocol or _emergencyWithdrawImpl: slippages[1..4]
// - deposit and withdrawals from protocol require four slippages:
//   - 1: portion to swap on uniswap
//   - 2: portion to swap on balancer
//   - 3: min out
//   - 4: ideal out
// Description:
// This is a liquid staking derivative strategy where eth is staked with Rocket
// pool to be used for spinning up validators. Users staking share is
// represented by rETH. The value of rETH compared to eth is growing with
// validation rewards collected by validators spinned up using the staked eth.
// The strategy uses the Rocket swap router to buy and sell rETH for eth. The
// swap calls have four parameters that control how exactly the swap takes
// place; portion to swap on Uniswap, portion to swap on Balancer, minimal out
// and ideal out. If ideal out is less then or equal to the internal rETH/eth
// price, the router will swap as much as possible internally. What cannot be
// swapped internally, will be swapped on Uniswap and Balancer, based on
// portions specified. Note that the portions are arbitrary numbers, what
// matters is just their ratio. At the end, the swapper checks if final swapped
// amount is at least min out, otherwise the transaction reverts. These
// parameters are passed in as slippages (see above for details).
contract REthHoldingStrategy is Strategy, WethHelper {
    using SafeERC20 for IERC20;

    IRocketSwapRouter public immutable rocketSwapRouter;
    IREthToken public immutable rEthToken;

    uint256 private _lastSharePrice;

    constructor(
        IAssetGroupRegistry assetGroupRegistry_,
        ISpoolAccessControl accessControl_,
        uint256 assetGroupId_,
        IRocketSwapRouter rocketSwapRouter_,
        address weth_
    ) Strategy(assetGroupRegistry_, accessControl_, assetGroupId_) WethHelper(weth_) {
        if (address(rocketSwapRouter_) == address(0)) {
            revert ConfigurationAddressZero();
        }

        rocketSwapRouter = rocketSwapRouter_;

        rEthToken = IREthToken(rocketSwapRouter_.rETH());
    }

    function initialize(string memory strategyName_) external initializer {
        __Strategy_init(strategyName_);

        address[] memory tokens = _assetGroupRegistry.listAssetGroup(_assetGroupId);

        if (tokens.length != 1 || tokens[0] != weth) {
            revert InvalidAssetGroup(_assetGroupId);
        }

        _lastSharePrice = _getSharePrice();
    }

    function assetRatio() external pure override returns (uint256[] memory) {
        uint256[] memory _assetRatio = new uint256[](1);
        _assetRatio[0] = 1;
        return _assetRatio;
    }

    function beforeDepositCheck(uint256[] memory amounts, uint256[] calldata slippages) public pure override {
        if (amounts[0] < slippages[1] || amounts[1] > slippages[2]) {
            revert REthHoldingBeforeDepositCheckFailed();
        }
    }

    function beforeRedeemalCheck(uint256 ssts, uint256[] calldata slippages) public pure override {
        if (
            (slippages[0] < 2 && (ssts < slippages[3] || ssts > slippages[4]))
                || (ssts < slippages[1] || ssts > slippages[2])
        ) {
            revert REthHoldingBeforeRedeemalCheckFailed();
        }
    }

    function _depositToProtocol(address[] calldata, uint256[] memory amounts, uint256[] calldata slippages)
        internal
        override
    {
        uint256 startingSlippage;
        if (slippages[0] == 0) {
            startingSlippage = 5;
        } else if (slippages[0] == 2) {
            startingSlippage = 3;
        } else {
            revert REthHoldingDepositSlippagesFailed();
        }

        unwrapEth(amounts[0]);

        rocketSwapRouter.swapTo{value: amounts[0]}(
            slippages[startingSlippage],
            slippages[startingSlippage + 1],
            slippages[startingSlippage + 2],
            slippages[startingSlippage + 3]
        );
    }

    function _redeemFromProtocol(address[] calldata, uint256 ssts, uint256[] calldata slippages) internal override {
        uint256 sharesToRedeem = rEthToken.balanceOf(address(this)) * ssts / totalSupply();
        uint256 startingSlippage;

        if (slippages[0] == 1) {
            startingSlippage = 5;
        } else if (slippages[0] == 2) {
            startingSlippage = 3;
        } else if (slippages[0] == 3) {
            startingSlippage = 1;
        } else {
            revert REthHoldingRedeemSlippagesFailed();
        }

        _redeemInternal(sharesToRedeem, slippages, startingSlippage);
    }

    function _emergencyWithdrawImpl(uint256[] calldata slippages, address recipient) internal override {
        uint256 sharesToRedeem = rEthToken.balanceOf(address(this));
        uint256 startingSlippage = 1;

        if (slippages[0] != 3) {
            revert REthHoldingRedeemSlippagesFailed();
        }

        uint256 bought = _redeemInternal(sharesToRedeem, slippages, startingSlippage);

        IERC20(weth).safeTransfer(recipient, bought);
    }

    function _compound(address[] calldata, SwapInfo[] calldata, uint256[] calldata)
        internal
        pure
        override
        returns (int256)
    {}

    function _getYieldPercentage(int256) internal override returns (int256 baseYieldPercentage) {
        uint256 currentSharePrice = _getSharePrice();

        baseYieldPercentage = _calculateYieldPercentage(_lastSharePrice, currentSharePrice);

        _lastSharePrice = currentSharePrice;
    }

    function _swapAssets(address[] memory, uint256[] memory, SwapInfo[] calldata) internal override {}

    function _getUsdWorth(uint256[] memory exchangeRates, IUsdPriceFeedManager priceFeedManager)
        internal
        view
        override
        returns (uint256)
    {
        uint256 assets = rEthToken.getEthValue(rEthToken.balanceOf(address(this)));

        return priceFeedManager.assetToUsdCustomPrice(weth, assets, exchangeRates[0]);
    }

    function _redeemInternal(uint256 amount, uint256[] memory slippages, uint256 startingSlippage)
        private
        returns (uint256 bought)
    {
        _resetAndApprove(IERC20(address(rEthToken)), address(rocketSwapRouter), amount);
        rocketSwapRouter.swapFrom(
            slippages[startingSlippage],
            slippages[startingSlippage + 1],
            slippages[startingSlippage + 2],
            slippages[startingSlippage + 3],
            amount
        );

        bought = address(this).balance;
        wrapEth(bought);
    }

    function _getSharePrice() private view returns (uint256) {
        return rEthToken.getEthValue(1 ether);
    }
}
