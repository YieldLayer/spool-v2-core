// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/token/ERC20/ERC20.sol";
import "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "./interfaces/CommonErrors.sol";
import "./interfaces/ISmartVault.sol";
import "./interfaces/RequestType.sol";
import "./access/SpoolAccessControl.sol";
import "./interfaces/IGuardManager.sol";

contract SmartVault is ERC20Upgradeable, ERC1155Upgradeable, SpoolAccessControllable, ISmartVault {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // @notice Guard manager
    IGuardManager internal immutable _guardManager;

    // @notice Vault name
    string internal _vaultName;

    // @notice Mapping from token ID => owner address
    mapping(uint256 => address) private _nftOwners;

    // @notice Deposit metadata registry
    mapping(uint256 => DepositMetadata) private _depositMetadata;

    // @notice Withdrawal metadata registry
    mapping(uint256 => WithdrawalMetadata) private _withdrawalMetadata;

    // @notice Asset group ID
    uint256 public override assetGroupId;

    // @notice Deposit NFT ID
    uint256 private _lastDepositId = 0;
    // @notice Maximal value of deposit NFT ID.
    uint256 private _maximalDepositId = 2 ** 255 - 1;

    // @notice Withdrawal NFT ID
    uint256 private _lastWithdrawalId = 2 ** 255;
    // @notice Maximal value of withdrawal NFT ID.
    uint256 private _maximalWithdrawalId = 2 ** 256 - 1;

    /* ========== CONSTRUCTOR ========== */

    /**
     * @notice Initializes variables
     * @param vaultName_ TODO
     * @param accessControl_ TODO
     * @param guardManager_ TODO
     */
    constructor(string memory vaultName_, ISpoolAccessControl accessControl_, IGuardManager guardManager_)
        SpoolAccessControllable(accessControl_)
    {
        _guardManager = guardManager_;
        _vaultName = vaultName_;
    }

    function initialize(uint256 assetGroupId_) external initializer {
        __ERC1155_init("");
        __ERC20_init("", "");
        assetGroupId = assetGroupId_;
    }

    /* ========== EXTERNAL VIEW FUNCTIONS ========== */

    /**
     * @return name Name of the vault
     */
    function vaultName() external view returns (string memory) {
        return _vaultName;
    }

    function getDepositMetadata(uint256 depositNftId) external view returns (DepositMetadata memory) {
        return _depositMetadata[depositNftId];
    }

    function getWithdrawalMetadata(uint256 withdrawalNftId) external view returns (WithdrawalMetadata memory) {
        return _withdrawalMetadata[withdrawalNftId];
    }

    /**
     * @dev Returns the total amount of the underlying asset that is “managed” by Vault.
     *
     * - SHOULD include any compounding that occurs from yield.
     * - MUST be inclusive of any fees that are charged against assets in the Vault.
     * - MUST NOT revert.
     */
    function totalAssets() external view returns (uint256[] memory) {
        revert("0");
    }

    /**
     * @dev Returns the amount of assets that the Vault would exchange for the amount of shares provided, in an ideal
     * scenario where all the conditions are met.
     * @param shares TODO
     *
     * - MUST NOT be inclusive of any fees that are charged against assets in the Vault.
     * - MUST NOT show any variations depending on the caller.
     * - MUST NOT reflect slippage or other on-chain conditions, when performing the actual exchange.
     * - MUST NOT revert.
     *
     * NOTE: This calculation MAY NOT reflect the “per-user” price-per-share, and instead should reflect the
     * “average-user’s” price-per-share, meaning what the average user should expect to see when exchanging to and
     * from.
     */
    function convertToAssets(uint256 shares) external view returns (uint256[] memory) {
        revert("0");
    }

    /* ========== EXTERNAL MUTATIVE FUNCTIONS ========== */

    function mint(address receiver, uint256 vaultShares) external onlyRole(ROLE_SMART_VAULT_MANAGER, msg.sender) {
        _mint(receiver, vaultShares);
    }

    function burn(address owner, uint256 vaultShares) external onlyRole(ROLE_SMART_VAULT_MANAGER, msg.sender) {
        // burn withdrawn vault shares
        _burn(owner, vaultShares);
    }

    function burnNFT(address owner, uint256 nftId, RequestType type_)
        external
        onlyRole(ROLE_SMART_VAULT_MANAGER, msg.sender)
    {
        // check validity and ownership of the NFT
        if (type_ == RequestType.Deposit && nftId > _maximalDepositId) {
            revert InvalidDepositNftId(nftId);
        }
        if (type_ == RequestType.Withdrawal && nftId <= _maximalDepositId) {
            revert InvalidWithdrawalNftId(nftId);
        }
        if (balanceOf(owner, nftId) != 1) {
            revert InvalidNftBalance(balanceOf(owner, nftId));
        }

        _burn(owner, nftId, 1);
    }

    function claimShares(address claimer, uint256 amount) external onlyRole(ROLE_SMART_VAULT_MANAGER, msg.sender) {
        _transfer(address(this), claimer, amount);
    }

    function releaseStrategyShares(address[] memory strategies, uint256[] memory shares)
        external
        onlyRole(ROLE_SMART_VAULT_MANAGER, msg.sender)
    {
        for (uint256 i = 0; i < strategies.length; i++) {
            IERC20(strategies[i]).safeTransfer(strategies[i], shares[i]);
        }
    }

    function mintDepositNFT(address receiver, DepositMetadata memory metadata)
        external
        onlyRole(ROLE_SMART_VAULT_MANAGER, msg.sender)
        returns (uint256)
    {
        if (_lastDepositId >= _maximalDepositId - 1) {
            revert DepositIdOverflow();
        }
        _lastDepositId++;
        _depositMetadata[_lastDepositId] = metadata;
        _mint(receiver, _lastDepositId, 1, "");

        return _lastDepositId;
    }

    function mintWithdrawalNFT(address receiver, WithdrawalMetadata memory metadata)
        external
        onlyRole(ROLE_SMART_VAULT_MANAGER, msg.sender)
        returns (uint256 receipt)
    {
        if (_lastWithdrawalId >= _maximalWithdrawalId - 1) {
            revert WithdrawalIdOverflow();
        }
        _lastWithdrawalId++;
        _withdrawalMetadata[_lastWithdrawalId] = metadata;
        _mint(receiver, _lastWithdrawalId, 1, "");

        return _lastWithdrawalId;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
        // mint / burn
        if (from == address(0) || to == address(0)) {
            return;
        }

        uint256[] memory assets = new uint256[](1);
        assets[0] = amount;

        RequestContext memory context =
            RequestContext(to, msg.sender, from, RequestType.TransferSVTs, assets, new address[](0));
        _guardManager.runGuards(address(this), context);
    }

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override {
        // mint
        if (from == address(0)) {
            return;
        }

        RequestContext memory context =
            RequestContext(to, operator, from, RequestType.TransferNFT, ids, new address[](0));
        _guardManager.runGuards(address(this), context);
    }

    function _afterTokenTransfer(
        address,
        address,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory
    ) internal virtual override {
        for (uint256 i; i < ids.length; i++) {
            require(amounts[i] == 1, "SmartVault::_afterTokenTransfer: Invalid NFT amount");
            _nftOwners[ids[i]] = to;
        }
    }
}
