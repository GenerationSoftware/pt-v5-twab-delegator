// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Clones } from "openzeppelin/proxy/Clones.sol";
import { ERC20, IERC20 } from "openzeppelin/token/ERC20/ERC20.sol";
import { IERC20Permit } from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "openzeppelin/interfaces/IERC4626.sol";
import { Address } from "openzeppelin/utils/Address.sol";

import { TwabController } from "pt-v5-twab-controller/TwabController.sol";

import { Delegation } from "./Delegation.sol";
import { LowLevelDelegator } from "./LowLevelDelegator.sol";
import { PermitAndMulticall } from "./PermitAndMulticall.sol";

/**
 * @title Delegate chances to win to multiple accounts.
 * @notice This contract allows accounts to easily delegate a portion of their Vault shares to multiple delegatees.
  The delegatees chance of winning prizes is increased by the delegated amount.
  If a delegator doesn't want to actively manage the delegations, then they can stake on the contract and appoint representatives.
 */
contract TwabDelegator is ERC20, LowLevelDelegator, PermitAndMulticall {
  using Address for address;
  using Clones for address;
  using SafeERC20 for IERC20;

  /* ============ Events ============ */

  /**
   * @notice Emitted when TwabController associated with this contract has been set.
   * @param twabController Address of the TwabController
   */
  event TwabControllerSet(TwabController indexed twabController);

  /**
   * @notice Emitted when Vault associated with this contract has been set.
   * @param vault Address of the Vault
   */
  event VaultSet(IERC20 indexed vault);

  /**
   * @notice Emitted when Vault shares have been staked.
   * @param delegator Address of the delegator
   * @param amount Amount of Vault shares shares staked
   */
  event VaultSharesStaked(address indexed delegator, uint256 amount);

  /**
   * @notice Emitted when Vault shares have been unstaked.
   * @param delegator Address of the delegator
   * @param recipient Address of the recipient that will receive the Vault shares
   * @param amount Amount of Vault shares unstaked
   */
  event VaultSharesUnstaked(address indexed delegator, address indexed recipient, uint256 amount);

  /**
   * @notice Emitted when a new delegation is created.
   * @param delegator Delegator of the delegation
   * @param slot Slot of the delegation
   * @param lockUntil Timestamp until which the delegation is locked
   * @param delegatee Address of the delegatee
   * @param delegation Address of the delegation that was created
   * @param user Address of the user who created the delegation
   */
  event DelegationCreated(
    address indexed delegator,
    uint256 indexed slot,
    uint96 lockUntil,
    address indexed delegatee,
    Delegation delegation,
    address user
  );

  /**
   * @notice Emitted when a delegatee is updated.
   * @param delegator Address of the delegator
   * @param slot Slot of the delegation
   * @param delegatee Address of the delegatee
   * @param lockUntil Timestamp until which the delegation is locked
   * @param user Address of the user who updated the delegatee
   */
  event DelegateeUpdated(
    address indexed delegator,
    uint256 indexed slot,
    address indexed delegatee,
    uint96 lockUntil,
    address user
  );

  /**
   * @notice Emitted when a delegation is funded.
   * @param delegator Address of the delegator
   * @param slot Slot of the delegation
   * @param amount Amount of Vault shares that were sent to the delegation
   * @param user Address of the user who funded the delegation
   */
  event DelegationFunded(
    address indexed delegator,
    uint256 indexed slot,
    uint256 amount,
    address indexed user
  );

  /**
   * @notice Emitted when a delegation is funded from the staked amount.
   * @param delegator Address of the delegator
   * @param slot Slot of the delegation
   * @param amount Amount of Vault shares that were sent to the delegation
   * @param user Address of the user who pulled funds from the delegator stake to the delegation
   */
  event DelegationFundedFromStake(
    address indexed delegator,
    uint256 indexed slot,
    uint256 amount,
    address indexed user
  );

  /**
   * @notice Emitted when an amount of Vault shares has been withdrawn from a delegation.
   * @dev The Vault shares are held by this contract and the delegator stake is increased.
   * @param delegator Address of the delegator
   * @param slot Slot of the delegation
   * @param amount Amount of Vault shares withdrawn
   * @param user Address of the user who withdrew the Vault shares
   */
  event WithdrewDelegationToStake(
    address indexed delegator,
    uint256 indexed slot,
    uint256 amount,
    address indexed user
  );

  /**
   * @notice Emitted when a delegator withdraws an amount of Vault shares from a delegation to a specified wallet.
   * @param delegator Address of the delegator
   * @param slot  Slot of the delegation
   * @param amount Amount of Vault shares withdrawn
   * @param to Recipient address of withdrawn Vault shares
   */
  event TransferredDelegation(
    address indexed delegator,
    uint256 indexed slot,
    uint256 amount,
    address indexed to
  );

  /**
   * @notice Emitted when a representative is set.
   * @param delegator Address of the delegator
   * @param representative Address of the representative
   * @param set Boolean indicating if the representative was set or unset
   */
  event RepresentativeSet(address indexed delegator, address indexed representative, bool set);

  /* ============ Variables ============ */

  /// @notice Vault to which this contract is tied to.
  IERC20 private immutable _vault;

  /// @notice TwabController to which this contract is tied to.
  TwabController private immutable _twabController;

  /// @notice Max lock time during which a delegation cannot be updated.
  uint256 public constant MAX_LOCK = 180 days;

  /**
   * @notice Representative elected by the delegator to handle delegation.
   * @dev Representative can only handle delegation and cannot withdraw Vault shares to their wallet.
   * @dev delegator => representative => bool allowing representative to represent the delegator
   */
  mapping(address => mapping(address => bool)) internal representatives;

  /* ============ Constructor ============ */

  /**
   * @notice Creates a new TWAB Delegator that is bound to the given vault contract.
   * @param name_ The name for the staked vault token
   * @param symbol_ The symbol for the staked vault token
   * @param twabController_ Address of the TwabController contract
   * @param vault_ Address of the Vault contract
   */
  constructor(
    string memory name_,
    string memory symbol_,
    TwabController twabController_,
    IERC20 vault_
  ) LowLevelDelegator() ERC20(name_, symbol_) {
    require(address(twabController_) != address(0), "TD/twabController-not-zero-addr");
    require(address(vault_) != address(0), "TD/vault-not-zero-addr");

    _twabController = twabController_;
    _vault = vault_;

    emit TwabControllerSet(twabController_);
    emit VaultSet(vault_);
  }

  /* ============ External Functions ============ */

  /**
   * @notice Stake `_amount` of Vault shares in this contract.
   * @dev Vault Shares can be staked on behalf of a `_to` user.
   * @param _to Address to which the stake will be attributed
   * @param _amount Amount of Vault shares to stake
   */
  function stake(address _to, uint256 _amount) external {
    _requireAmountGtZero(_amount);

    _vault.safeTransferFrom(msg.sender, address(this), _amount);
    _mint(_to, _amount);

    emit VaultSharesStaked(_to, _amount);
  }

  /**
   * @notice Unstake `_amount` of Vault shares from this contract. Transfers Vault shares to the passed `_to` address.
   * @dev If delegator has delegated his whole stake, he will first have to withdraw from a delegation to be able to unstake.
   * @param _to Address of the recipient that will receive the Vault shares
   * @param _amount Amount of Vault shares to unstake
   */
  function unstake(address _to, uint256 _amount) external {
    _requireRecipientNotZeroAddress(_to);
    _requireAmountGtZero(_amount);

    _burn(msg.sender, _amount);

    _vault.safeTransfer(_to, _amount);

    emit VaultSharesUnstaked(msg.sender, _to, _amount);
  }

  /**
   * @notice Creates a new delegation.
   This will create a new Delegation contract for the given slot and have it delegate its Vault shares to the given delegatee.
   If a non-zero lock duration is passed, then the delegatee cannot be changed, nor funding withdrawn, until the lock has expired.
   * @dev The `_delegator` and `_slot` params are used to compute the salt of the delegation
   * @param _delegator Address of the delegator that will be able to handle the delegation
   * @param _slot Slot of the delegation
   * @param _delegatee Address of the delegatee
   * @param _lockDuration Duration of time for which the delegation is locked. Must be less than the max duration.
   * @return Returns the address of the Delegation contract that will hold the Vault shares
   */
  function createDelegation(
    address _delegator,
    uint256 _slot,
    address _delegatee,
    uint96 _lockDuration
  ) external returns (Delegation) {
    _requireDelegatorOrRepresentative(_delegator);
    _requireDelegateeNotZeroAddress(_delegatee);
    _requireLockDuration(_lockDuration);

    uint96 _lockUntil = _computeLockUntil(_lockDuration);

    Delegation _delegation = _createDelegation(
      _computeSalt(_delegator, bytes32(_slot)),
      _lockUntil
    );

    _setDelegateeCall(_delegation, _delegatee);

    emit DelegationCreated(_delegator, _slot, _lockUntil, _delegatee, _delegation, msg.sender);

    return _delegation;
  }

  /**
   * @notice Updates the delegatee and lock duration for a delegation slot.
   * @dev Only callable by the `_delegator` or their representative.
   * @dev Will revert if delegation is still locked.
   * @param _delegator Address of the delegator
   * @param _slot Slot of the delegation
   * @param _delegatee Address of the delegatee
   * @param _lockDuration Duration of time during which the delegatee cannot be changed nor withdrawn
   * @return The address of the Delegation
   */
  function updateDelegatee(
    address _delegator,
    uint256 _slot,
    address _delegatee,
    uint96 _lockDuration
  ) external returns (Delegation) {
    _requireDelegatorOrRepresentative(_delegator);
    _requireDelegateeNotZeroAddress(_delegatee);
    _requireLockDuration(_lockDuration);

    Delegation _delegation = Delegation(_computeAddress(_delegator, _slot));
    _requireDelegationUnlocked(_delegation);

    uint96 _lockUntil = _computeLockUntil(_lockDuration);

    if (_lockDuration > 0) {
      _delegation.setLockUntil(_lockUntil);
    }

    _setDelegateeCall(_delegation, _delegatee);

    emit DelegateeUpdated(_delegator, _slot, _delegatee, _lockUntil, msg.sender);

    return _delegation;
  }

  /**
   * @notice Fund a delegation by transferring Vault shares from the caller to the delegation.
   * @dev Callable by anyone.
   * @dev Will revert if delegation does not exist.
   * @param _delegator Address of the delegator
   * @param _slot Slot of the delegation
   * @param _amount Amount of Vault shares to transfer
   * @return The address of the Delegation
   */
  function fundDelegation(
    address _delegator,
    uint256 _slot,
    uint256 _amount
  ) external returns (Delegation) {
    require(_delegator != address(0), "TD/dlgtr-not-zero-adr");
    _requireAmountGtZero(_amount);

    Delegation _delegation = Delegation(_computeAddress(_delegator, _slot));
    _vault.safeTransferFrom(msg.sender, address(_delegation), _amount);

    emit DelegationFunded(_delegator, _slot, _amount, msg.sender);

    return _delegation;
  }

  /**
   * @notice Fund a delegation using the `_delegator` stake.
   * @dev Callable only by the `_delegator` or a representative.
   * @dev Will revert if delegation does not exist.
   * @dev Will revert if `_amount` is greater than the staked amount.
   * @param _delegator Address of the delegator
   * @param _slot Slot of the delegation
   * @param _amount Amount of Vault shares to send to the delegation from the staked amount
   * @return The address of the Delegation
   */
  function fundDelegationFromStake(
    address _delegator,
    uint256 _slot,
    uint256 _amount
  ) external returns (Delegation) {
    _requireDelegatorOrRepresentative(_delegator);
    _requireAmountGtZero(_amount);

    Delegation _delegation = Delegation(_computeAddress(_delegator, _slot));

    _burn(_delegator, _amount);

    _vault.safeTransfer(address(_delegation), _amount);

    emit DelegationFundedFromStake(_delegator, _slot, _amount, msg.sender);

    return _delegation;
  }

  /**
   * @notice Withdraw Vault shares from a delegation. The Vault shares will be held by this contract and the delegator's stake will increase.
   * @dev Only callable by the `_delegator` or a representative.
   * @dev Will send the Vault shares to this contract and increase the `_delegator` staked amount.
   * @dev Will revert if delegation is still locked.
   * @param _delegator Address of the delegator
   * @param _slot Slot of the delegation
   * @param _amount Amount of Vault shares to withdraw
   * @return The address of the Delegation
   */
  function withdrawDelegationToStake(
    address _delegator,
    uint256 _slot,
    uint256 _amount
  ) external returns (Delegation) {
    _requireDelegatorOrRepresentative(_delegator);

    Delegation _delegation = Delegation(_computeAddress(_delegator, _slot));

    _transfer(_delegation, address(this), _amount);

    _mint(_delegator, _amount);

    emit WithdrewDelegationToStake(_delegator, _slot, _amount, msg.sender);

    return _delegation;
  }

  /**
   * @notice Withdraw an `_amount` of Vault shares from a delegation. The delegator is assumed to be the caller.
   * @dev Vault Shares are sent directly to the passed `_to` address.
   * @dev Will revert if delegation is still locked.
   * @param _slot Slot of the delegation
   * @param _amount Amount to withdraw
   * @param _to Account to transfer the withdrawn Vault shares to
   * @return The address of the Delegation
   */
  function transferDelegationTo(
    uint256 _slot,
    uint256 _amount,
    address _to
  ) external returns (Delegation) {
    _requireRecipientNotZeroAddress(_to);

    Delegation _delegation = Delegation(_computeAddress(msg.sender, _slot));
    _transfer(_delegation, _to, _amount);

    emit TransferredDelegation(msg.sender, _slot, _amount, _to);

    return _delegation;
  }

  /**
   * @notice Allow an account to set or unset a `_representative` to handle delegation.
   * @dev If `_set` is `true`, `_representative` will be set as representative of `msg.sender`.
   * @dev If `_set` is `false`, `_representative` will be unset as representative of `msg.sender`.
   * @param _representative Address of the representative
   * @param _set Set or unset the representative
   */
  function setRepresentative(address _representative, bool _set) external {
    require(_representative != address(0), "TD/rep-not-zero-addr");

    representatives[msg.sender][_representative] = _set;

    emit RepresentativeSet(msg.sender, _representative, _set);
  }

  /**
   * @notice Returns whether or not the given rep is a representative of the delegator.
   * @param _delegator The delegator
   * @param _representative The representative to check for
   * @return True if the rep is a rep, false otherwise
   */
  function isRepresentativeOf(
    address _delegator,
    address _representative
  ) external view returns (bool) {
    return representatives[_delegator][_representative];
  }

  /**
   * @notice Allows a user to call multiple functions on the same contract.  Useful for EOA who wants to batch transactions.
   * @param _data An array of encoded function calls.  The calls must be abi-encoded calls to this contract.
   * @return The results from each function call
   */
  function multicall(bytes[] calldata _data) external returns (bytes[] memory) {
    return _multicall(_data);
  }

  /**
   * @notice Alow a user to approve Vault shares and run various calls in one transaction.
   * @param _amount Amount of Vault shares to approve
   * @param _permitSignature Permit signature
   * @param _data Datas to call with `functionDelegateCall`
   */
  function permitAndMulticall(
    uint256 _amount,
    Signature calldata _permitSignature,
    bytes[] calldata _data
  ) external {
    _permitAndMulticall(IERC20Permit(address(_vault)), _amount, _permitSignature, _data);
  }

  /**
   * @notice Allows the caller to easily get the details for a delegation.
   * @param _delegator The delegator address
   * @param _slot The delegation slot they are using
   * @return delegation The address that holds Vault shares for the delegation
   * @return delegatee The address that Vault shares are being delegated to
   * @return balance The balance of Vault shares in the delegation
   * @return lockUntil The timestamp at which the delegation unlocks
   * @return wasCreated Whether or not the delegation has been created
   */
  function getDelegation(
    address _delegator,
    uint256 _slot
  )
    external
    view
    returns (
      Delegation delegation,
      address delegatee,
      uint256 balance,
      uint256 lockUntil,
      bool wasCreated
    )
  {
    delegation = Delegation(_computeAddress(_delegator, _slot));
    wasCreated = address(delegation).isContract();
    delegatee = _twabController.delegateOf(address(_vault), address(delegation));
    balance = _vault.balanceOf(address(delegation));

    if (wasCreated) {
      lockUntil = delegation.lockUntil();
    }
  }

  /**
   * @notice Computes the address of the delegation for the delegator + slot combination.
   * @param _delegator The user who is delegating Vault shares
   * @param _slot The delegation slot
   * @return The address of the delegation.  This is the address that holds the balance of Vault shares.
   */
  function computeDelegationAddress(
    address _delegator,
    uint256 _slot
  ) external view returns (address) {
    return _computeAddress(_delegator, _slot);
  }

  /**
   * @notice Returns the ERC20 token decimals.
   * @dev This value is equal to the decimals of the Vault shares being delegated.
   * @return ERC20 token decimals
   */
  function decimals() public view virtual override returns (uint8) {
    return ERC20(address(_vault)).decimals();
  }

  /**
   * @notice Returns the TwabController address.
   * @return TwabController address
   */
  function twabController() external view returns (address) {
    return address(_twabController);
  }

  /**
   * @notice Returns the Vault address.
   * @return Vault address
   */
  function vault() external view returns (address) {
    return address(_vault);
  }

  /* ============ Internal Functions ============ */

  /**
   * @notice Computes the address of a delegation contract using the delegator and slot as a salt.
   The contract is a clone, also known as minimal proxy contract.
   * @param _delegator Address of the delegator
   * @param _slot Slot of the delegation
   * @return Address at which the delegation contract will be deployed
   */
  function _computeAddress(address _delegator, uint256 _slot) internal view returns (address) {
    return _computeAddress(_computeSalt(_delegator, bytes32(_slot)));
  }

  /**
   * @notice Computes the timestamp at which the delegation unlocks, after which the delegatee can be changed and Vault shares withdrawn.
   * @param _lockDuration The duration of the lock
   * @return The lock expiration timestamp
   */
  function _computeLockUntil(uint96 _lockDuration) internal view returns (uint96) {
    unchecked {
      return uint96(block.timestamp) + _lockDuration;
    }
  }

  /**
   * @notice Delegates Vault shares from the `_delegation` contract to the `_delegatee` address.
   * @param _delegation Address of the delegation contract
   * @param _delegatee Address of the delegatee
   */
  function _setDelegateeCall(Delegation _delegation, address _delegatee) internal {
    bytes4 _selector = _twabController.delegate.selector;
    bytes memory _data = abi.encodeWithSelector(_selector, address(_vault), _delegatee);

    _executeCall(_delegation, address(_twabController), _data);
  }

  /**
   * @notice Tranfers Vault shares from the Delegation contract to the `_to` address.
   * @param _delegation Address of the delegation contract
   * @param _to Address of the recipient
   * @param _amount Amount of Vault shares to transfer
   */
  function _transferCall(Delegation _delegation, address _to, uint256 _amount) internal {
    bytes4 _selector = _vault.transfer.selector;
    bytes memory _data = abi.encodeWithSelector(_selector, _to, _amount);

    _executeCall(_delegation, address(_vault), _data);
  }

  /**
   * @notice Execute a function call on the delegation contract.
   * @param _delegation Address of the delegation contract
   * @param _to The address that will be called
   * @param _data The call data that will be executed
   * @return The return datas from the calls
   */
  function _executeCall(
    Delegation _delegation,
    address _to,
    bytes memory _data
  ) internal returns (bytes[] memory) {
    Delegation.Call[] memory _calls = new Delegation.Call[](1);
    _calls[0] = Delegation.Call({ to: _to, data: _data });

    return _delegation.executeCalls(_calls);
  }

  /**
   * @notice Transfers Vault shares from a delegation contract to `_to`.
   * @param _delegation Address of the delegation contract
   * @param _to Address of the recipient
   * @param _amount Amount of Vault shares to transfer
   */
  function _transfer(Delegation _delegation, address _to, uint256 _amount) internal {
    _requireAmountGtZero(_amount);
    _requireDelegationUnlocked(_delegation);

    _transferCall(_delegation, _to, _amount);
  }

  /* ============ Modifier/Require Functions ============ */

  /**
   * @notice Require to only allow the delegator or representative to call a function.
   * @param _delegator Address of the delegator
   */
  function _requireDelegatorOrRepresentative(address _delegator) internal view {
    require(
      _delegator == msg.sender || representatives[_delegator][msg.sender],
      "TD/not-dlgtr-or-rep"
    );
  }

  /**
   * @notice Require to verify that `_delegatee` is not address zero.
   * @param _delegatee Address of the delegatee
   */
  function _requireDelegateeNotZeroAddress(address _delegatee) internal pure {
    require(_delegatee != address(0), "TD/dlgt-not-zero-addr");
  }

  /**
   * @notice Require to verify that `_amount` is greater than 0.
   * @param _amount Amount to check
   */
  function _requireAmountGtZero(uint256 _amount) internal pure {
    require(_amount > 0, "TD/amount-gt-zero");
  }

  /**
   * @notice Require to verify that `_to` is not address zero.
   * @param _to Address to check
   */
  function _requireRecipientNotZeroAddress(address _to) internal pure {
    require(_to != address(0), "TD/to-not-zero-addr");
  }

  /**
   * @notice Require to verify if a `_delegation` is locked.
   * @param _delegation Delegation to check
   */
  function _requireDelegationUnlocked(Delegation _delegation) internal view {
    require(block.timestamp >= _delegation.lockUntil(), "TD/delegation-locked");
  }

  /**
   * @notice Require to verify that a `_lockDuration` does not exceed the maximum lock duration.
   * @param _lockDuration Lock duration to check
   */
  function _requireLockDuration(uint256 _lockDuration) internal pure {
    require(_lockDuration <= MAX_LOCK, "TD/lock-too-long");
  }
}
