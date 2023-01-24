// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.16;

import {console} from "forge-std/console.sol";

import "@openzeppelin/security/ReentrancyGuard.sol";
import "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "../access/SpoolAccessControl.sol";
import "../interfaces/IRewardManager.sol";
import "../interfaces/ISmartVault.sol";
import "../utils/MathUtils.sol";
import "../interfaces/IAssetGroupRegistry.sol";
import "../interfaces/ISmartVaultManager.sol";

contract RewardManager is IRewardManager, ReentrancyGuard, SpoolAccessControllable {
    using SafeERC20 for IERC20;
    /* ========== CONSTANTS ========== */

    /// @notice Multiplier used when dealing reward calculations
    uint256 private constant REWARD_ACCURACY = 1e18;

    /* ========== STATE VARIABLES ========== */

    /// @notice Asset group registry
    IAssetGroupRegistry private _assetGroupRegistry;

    /// @notice Smart vault balance viewer
    ISmartVaultBalance private _smartVaultBalance;

    /// @notice Number of vault incentivized tokens
    mapping(address => uint8) public rewardTokensCount;

    /// @notice All reward tokens supported by the contract
    mapping(address => mapping(uint256 => IERC20)) public rewardTokens;

    /// @notice Vault reward token incentive configuration
    mapping(address => mapping(IERC20 => RewardConfiguration)) public rewardConfiguration;

    mapping(address => mapping(IERC20 => bool)) tokenBlacklist;

    constructor(
        ISpoolAccessControl spoolAccessControl,
        IAssetGroupRegistry assetGroupRegistry_,
        ISmartVaultBalance smartVaultBalance_
    ) SpoolAccessControllable(spoolAccessControl) {
        _assetGroupRegistry = assetGroupRegistry_;
        _smartVaultBalance = smartVaultBalance_;
    }

    /* ========== VIEWS ========== */

    function lastTimeRewardApplicable(address smartVault, IERC20 token) public view returns (uint32) {
        return uint32(MathUtils.min(block.timestamp, rewardConfiguration[smartVault][token].periodFinish));
    }

    /**
     * @notice Blacklisted force-removed tokens
     */
    function tokenBlacklisted(address smartVault, IERC20 token) external view returns (bool) {
        return tokenBlacklist[smartVault][token];
    }

    /**
     * @notice Reward amount per assets deposited
     */
    function rewardPerToken(address smartVault, IERC20 token) public view returns (uint224) {
        RewardConfiguration storage config = rewardConfiguration[smartVault][token];

        if (_totalDeposits(smartVault) == 0) {
            return config.rewardPerTokenStored;
        }

        uint256 timeDelta = lastTimeRewardApplicable(smartVault, token) - config.lastUpdateTime;

        if (timeDelta == 0) {
            return config.rewardPerTokenStored;
        }

        return SafeCast.toUint224(
            config.rewardPerTokenStored + ((timeDelta * config.rewardRate) / _totalDeposits(smartVault))
        );
    }

    /**
     * @notice Amount of rewards earned
     */
    function earned(address smartVault, IERC20 token, address account) public view returns (uint256) {
        RewardConfiguration storage config = rewardConfiguration[smartVault][token];

        uint256 userShares = _userDeposits(smartVault, account); // SVT-ji 1000

        if (userShares == 0) {
            return config.rewards[account];
        }

        uint256 userRewardPerTokenPaid = config.userRewardPerTokenPaid[account];

        return ((userShares * (rewardPerToken(smartVault, token) - userRewardPerTokenPaid)) / REWARD_ACCURACY)
            + config.rewards[account];
    }

    function getRewardForDuration(address smartVault, IERC20 token) external view returns (uint256) {
        RewardConfiguration storage config = rewardConfiguration[smartVault][token];
        return uint256(config.rewardRate) * config.rewardsDuration;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Claim rewards
     */
    function claimRewards(address smartVault, IERC20[] memory tokens) external nonReentrant {
        for (uint256 i; i < tokens.length; i++) {
            _claimReward(smartVault, tokens[i], msg.sender);
        }
    }

    /**
     * @notice Claim rewards for given account
     */
    function claimRewardsFor(address smartVault, address account)
        external
        override
        onlyRole(ROLE_SMART_VAULT_MANAGER, msg.sender)
        nonReentrant
    {
        uint256 _rewardTokensCount = rewardTokensCount[smartVault];
        for (uint256 i; i < _rewardTokensCount; i++) {
            _claimReward(smartVault, rewardTokens[smartVault][i], account);
        }
    }

    function _claimReward(address smartVault, IERC20 token, address account)
        internal
        updateReward(smartVault, token, account)
    {
        RewardConfiguration storage config = rewardConfiguration[smartVault][token];

        require(config.rewardsDuration != 0, "BTK");

        uint256 reward = config.rewards[account];
        if (reward > 0) {
            config.rewards[account] = 0;
            token.safeTransfer(account, reward);
            emit RewardPaid(smartVault, token, account, reward);
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /**
     * @notice Allows a new token to be added to the reward system
     *
     * @dev
     * Emits an {TokenAdded} event indicating the newly added reward token
     * and configuration
     *
     * Requirements:
     *
     * - the caller must be the reward distributor
     * - the reward duration must be non-zero
     * - the token must not have already been added
     *
     */
    function addToken(address smartVault, IERC20 token, uint32 rewardsDuration, uint256 reward)
        external
        onlyAdminOrVaultAdmin(smartVault, msg.sender)
        exceptUnderlying(smartVault, token)
    {
        RewardConfiguration storage config = rewardConfiguration[smartVault][token];

        if (tokenBlacklist[smartVault][token]) revert RewardTokenBlacklisted(address(token));
        if (config.lastUpdateTime != 0) revert RewardTokenAlreadyAdded(address(token));
        if (rewardsDuration == 0) revert InvalidRewardDuration();
        if (rewardTokensCount[smartVault] > 5) revert RewardTokenCapReached();

        rewardTokens[smartVault][rewardTokensCount[smartVault]] = token;
        rewardTokensCount[smartVault]++;

        config.rewardsDuration = rewardsDuration;

        if (reward > 0) {
            _extendRewardEmission(smartVault, token, reward);
        }
    }

    /**
     * @notice Extend reward emission
     */
    function extendRewardEmission(address smartVault, IERC20 token, uint256 reward, uint32 rewardsDuration)
        external
        onlyAdminOrVaultAdmin(smartVault, msg.sender)
        exceptUnderlying(smartVault, token)
    {
        if (tokenBlacklist[smartVault][token]) revert RewardTokenBlacklisted(address(token));
        if (rewardsDuration == 0) revert InvalidRewardDuration();
        if (rewardConfiguration[smartVault][token].lastUpdateTime == 0) {
            revert InvalidRewardToken(address(token));
        }

        rewardConfiguration[smartVault][token].rewardsDuration = rewardsDuration;
        _extendRewardEmission(smartVault, token, reward);
    }

    function _extendRewardEmission(address smartVault, IERC20 token, uint256 reward)
        private
        updateReward(smartVault, token, address(0))
    {
        RewardConfiguration storage config = rewardConfiguration[smartVault][token];

        require(config.rewardPerTokenStored + (reward * REWARD_ACCURACY) <= type(uint192).max, "RTB");

        token.safeTransferFrom(msg.sender, address(this), reward);
        uint32 newPeriodFinish = uint32(block.timestamp) + config.rewardsDuration;

        if (block.timestamp >= config.periodFinish) {
            config.rewardRate = SafeCast.toUint192((reward * REWARD_ACCURACY) / config.rewardsDuration);
            emit RewardAdded(smartVault, token, reward, config.rewardsDuration);
        } else {
            // If extending or adding additional rewards,
            // cannot set new finish time to be less than previously configured
            require(config.periodFinish <= newPeriodFinish, "PFS");
            uint256 remaining = config.periodFinish - block.timestamp;
            uint256 leftover = remaining * config.rewardRate;
            uint192 newRewardRate = SafeCast.toUint192((reward * REWARD_ACCURACY + leftover) / config.rewardsDuration);
            require(newRewardRate >= config.rewardRate, "LRR");

            config.rewardRate = newRewardRate;
            emit RewardExtended(smartVault, token, reward, leftover, config.rewardsDuration, newPeriodFinish);
        }

        config.lastUpdateTime = uint32(block.timestamp);
        config.periodFinish = newPeriodFinish;
    }

    /**
     * @notice End rewards emission earlier
     */
    function updatePeriodFinish(address smartVault, IERC20 token, uint32 timestamp)
        external
        onlyAdminOrVaultAdmin(smartVault, msg.sender)
        updateReward(smartVault, token, address(0))
    {
        if (rewardConfiguration[smartVault][token].lastUpdateTime > timestamp) {
            rewardConfiguration[smartVault][token].periodFinish = rewardConfiguration[smartVault][token].lastUpdateTime;
        } else {
            rewardConfiguration[smartVault][token].periodFinish = timestamp;
        }

        emit PeriodFinishUpdated(smartVault, token, rewardConfiguration[smartVault][token].periodFinish);
    }

    /**
     * @notice Claim reward tokens
     * @dev
     * This is meant to be an emergency function to claim reward tokens.
     * Users that have not claimed yet will not be able to claim as
     * the rewards will be removed.
     *
     * Requirements:
     *
     * - the caller must be Spool DAO
     * - cannot claim vault underlying token
     * - cannot only execute if the reward finished
     *
     * @param token Token address to remove
     * @param amount Amount of tokens to claim
     */
    function claimFinishedRewards(address smartVault, IERC20 token, uint256 amount)
        external
        onlyAdminOrVaultAdmin(smartVault, msg.sender)
        exceptUnderlying(smartVault, token)
        onlyFinished(smartVault, token)
    {
        token.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Force remove reward from vault rewards configuration.
     * @dev This is meant to be an emergency function if a reward token breaks.
     *
     * Requirements:
     *
     * - the caller must be Spool DAO
     *
     * @param token Token address to remove
     */
    function forceRemoveReward(address smartVault, IERC20 token)
        external
        onlyAdminOrVaultAdmin(smartVault, msg.sender)
    {
        tokenBlacklist[smartVault][token] = true;
        _removeReward(smartVault, token);

        delete rewardConfiguration[smartVault][token];
    }

    /**
     * @notice Remove reward from vault rewards configuration.
     * @dev
     * Used to sanitize vault and save on gas, after the reward has ended.
     * Users will be able to claim rewards
     *
     * Requirements:
     *
     * - the caller must be the spool owner or Spool DAO
     * - cannot claim vault underlying token
     * - cannot only execute if the reward finished
     *
     * @param token Token address to remove
     */
    function removeReward(address smartVault, IERC20 token)
        external
        onlyAdminOrVaultAdmin(smartVault, msg.sender)
        onlyFinished(smartVault, token)
        updateReward(smartVault, token, address(0))
    {
        _removeReward(smartVault, token);
    }

    /**
     * @notice Syncs rewards across all tokens of the system
     *
     * @dev This function should be invoked every time user's vault share changes
     */
    function updateRewardsOnVault(address smartVault, address account)
        public
        onlyRole(ROLE_SMART_VAULT_MANAGER, msg.sender)
    {
        _updateRewards(smartVault, account);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _updateRewards(address smartVault, address account) private {
        uint256 _rewardTokensCount = rewardTokensCount[smartVault];

        for (uint256 i; i < _rewardTokensCount; i++) {
            _updateReward(smartVault, rewardTokens[smartVault][i], account);
        }
    }

    function _totalDeposits(address smartVault) private view returns (uint256) {
        return IERC20(smartVault).totalSupply();
    }

    function _updateReward(address smartVault, IERC20 token, address account) private {
        RewardConfiguration storage config = rewardConfiguration[smartVault][token];
        config.rewardPerTokenStored = rewardPerToken(smartVault, token);
        config.lastUpdateTime = lastTimeRewardApplicable(smartVault, token);
        if (account != address(0)) {
            config.rewards[account] = earned(smartVault, token, account);
            config.userRewardPerTokenPaid[account] = config.rewardPerTokenStored;
        }
    }

    function _removeReward(address smartVault, IERC20 token) private {
        uint256 _rewardTokensCount = rewardTokensCount[smartVault];
        for (uint256 i; i < _rewardTokensCount; i++) {
            if (rewardTokens[smartVault][i] == token) {
                rewardTokens[smartVault][i] = rewardTokens[smartVault][_rewardTokensCount - 1];

                delete rewardTokens[smartVault][_rewardTokensCount- 1];
                rewardTokensCount[smartVault]--;
                emit RewardRemoved(smartVault, token);

                break;
            }
        }
    }

    function _exceptUnderlying(address smartVault, IERC20 token) private view {
        address[] memory vaultTokens = _assetGroupRegistry.listAssetGroup(ISmartVault(smartVault).assetGroupId());
        for (uint256 i = 0; i < vaultTokens.length; i++) {
            if (vaultTokens[i] == address(token)) {
                revert AssetGroupToken(address(token));
            }
        }
    }

    function _onlyFinished(address smartVault, IERC20 token) private view {
        require(block.timestamp > rewardConfiguration[smartVault][token].periodFinish, "RNF");
    }

    function _userDeposits(address smartVault, address account) private view returns (uint256) {
        return _smartVaultBalance.getUserSVTBalance(smartVault, account);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address smartVault, IERC20 token, address account) {
        _updateReward(smartVault, token, account);
        _;
    }

    modifier exceptUnderlying(address smartVault, IERC20 token) {
        _exceptUnderlying(smartVault, token);
        _;
    }

    modifier onlyFinished(address smartVault, IERC20 token) {
        _onlyFinished(smartVault, token);
        _;
    }
}
