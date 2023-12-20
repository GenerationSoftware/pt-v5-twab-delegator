// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { console2 } from "forge-std/console2.sol";

import { ERC4626Mock, IERC20, IERC20Metadata } from "openzeppelin/mocks/ERC4626Mock.sol";

import { TwabController } from "pt-v5-twab-controller/TwabController.sol";
import { ERC20, PrizePool, VaultV2 as Vault } from "pt-v5-vault/Vault.sol";

import { ERC20PermitMock } from "./contracts/mock/ERC20PermitMock.sol";

import { PermitAndMulticall } from "../src/PermitAndMulticall.sol";
import { TwabDelegator } from "../src/TwabDelegator.sol";

import { Delegation, Helpers } from "./utils/Helpers.t.sol";

contract TwabDelegatorTest is Helpers {
  /* ============ Events ============ */
  event TwabControllerSet(TwabController indexed twabController);

  event VaultSet(Vault indexed vault);

  event VaultSharesStaked(address indexed delegator, uint256 amount);

  event VaultSharesUnstaked(address indexed delegator, address indexed recipient, uint256 amount);

  event DelegationCreated(
    address indexed delegator,
    uint256 indexed slot,
    uint96 lockUntil,
    address indexed delegatee,
    Delegation delegation,
    address user
  );

  event DelegateeUpdated(
    address indexed delegator,
    uint256 indexed slot,
    address indexed delegatee,
    uint96 lockUntil,
    address user
  );

  event WithdrewDelegationToStake(
    address indexed delegator,
    uint256 indexed slot,
    uint256 amount,
    address indexed user
  );

  event DelegationFunded(
    address indexed delegator,
    uint256 indexed slot,
    uint256 amount,
    address indexed user
  );

  event DelegationFundedFromStake(
    address indexed delegator,
    uint256 indexed slot,
    uint256 amount,
    address indexed user
  );

  event TransferredDelegation(
    address indexed delegator,
    uint256 indexed slot,
    uint256 amount,
    address indexed to
  );

  event RepresentativeSet(address indexed delegator, address indexed representative, bool set);

  /* ============ Variables ============ */
  address public owner;
  uint256 public ownerPrivateKey;

  address public representative;
  uint256 public representativePrivateKey;

  address public alice;
  uint256 public alicePrivateKey;

  address public bob;
  uint256 public bobPrivateKey;

  address public constant SPONSORSHIP_ADDRESS = address(1);

  Vault public vault;
  string public vaultName = "PoolTogether aEthDAI Prize Token (PTaEthDAI)";
  string public vaultSymbol = "PTaEthDAI";

  TwabDelegator public twabDelegator;
  string public twabDelegatorName = "PoolTogether Staked aEthDAI Prize Token (stkPTaEthDAI)";
  string public twabDelegatorSymbol = "stkPTaEthDAI";

  ERC4626Mock public yieldVault;
  ERC20PermitMock public underlyingAsset;
  ERC20PermitMock public prizeToken;

  address public claimer;
  PrizePool public prizePool;

  uint256 public winningRandomNumber = 123456;
  uint32 public drawPeriodSeconds = 1 days;
  TwabController public twabController;

  function setUp() public {
    (owner, ownerPrivateKey) = makeAddrAndKey("Owner");
    (representative, representativePrivateKey) = makeAddrAndKey("Representative");
    (alice, alicePrivateKey) = makeAddrAndKey("Alice");
    (bob, bobPrivateKey) = makeAddrAndKey("Bob");

    underlyingAsset = new ERC20PermitMock("Dai Stablecoin");
    prizeToken = new ERC20PermitMock("PoolTogether");

    twabController = new TwabController(1 days, uint32(block.timestamp));

    prizePool = PrizePool(address(0x8C66F3693f99b2582630405e07A8054AD842DD5A));

    claimer = address(0xe291d9169F0316272482dD82bF297BB0a11D267f);

    yieldVault = new ERC4626Mock(address(underlyingAsset));

    vm.mockCall(
      address(prizePool),
      abi.encodeWithSelector(bytes4(keccak256("twabController()"))),
      abi.encode(twabController)
    );
    vault = new Vault(
      underlyingAsset,
      vaultName,
      vaultSymbol,
      yieldVault,
      prizePool,
      claimer,
      address(this),
      0,
      address(this)
    );

    twabDelegator = new TwabDelegator(
      twabDelegatorName,
      twabDelegatorSymbol,
      twabController,
      vault
    );
  }

  /* ============ Constructor ============ */

  function testConstructor() public {
    vm.expectEmit();

    emit VaultSet(vault);
    emit TwabControllerSet(twabController);

    TwabDelegator testTwabDelegator = new TwabDelegator(
      twabDelegatorName,
      twabDelegatorSymbol,
      twabController,
      vault
    );

    uint256 assetDecimals = ERC20(address(underlyingAsset)).decimals();

    assertEq(testTwabDelegator.name(), twabDelegatorName);
    assertEq(testTwabDelegator.symbol(), twabDelegatorSymbol);
    assertEq(testTwabDelegator.decimals(), assetDecimals);
    assertEq(testTwabDelegator.twabController(), address(twabController));
    assertEq(testTwabDelegator.vault(), address(vault));
  }

  function testConstructorTwabControllerNotZero() public {
    vm.expectRevert(bytes("TD/twabController-not-zero-addr"));

    new TwabDelegator(twabDelegatorName, twabDelegatorSymbol, TwabController(address(0)), vault);
  }

  function testConstructorVaultNotZero() public {
    vm.expectRevert(bytes("TD/vault-not-zero-addr"));

    new TwabDelegator(twabDelegatorName, twabDelegatorSymbol, twabController, Vault(address(0)));
  }

  /* ============ Stake ============ */

  function testStake() public {
    uint256 _amount = 1000e18;

    vm.startPrank(alice);

    underlyingAsset.mint(alice, _amount);
    _deposit(underlyingAsset, vault, _amount, alice);

    vault.approve(address(twabDelegator), type(uint256).max);

    vm.expectEmit();
    emit VaultSharesStaked(alice, _amount);

    twabDelegator.stake(alice, _amount);

    assertEq(vault.balanceOf(alice), 0);
    assertEq(vault.balanceOf(address(twabDelegator)), _amount);
    assertEq(twabDelegator.balanceOf(alice), _amount);

    vm.stopPrank();
  }

  function testStakeOnBehalf() public {
    uint256 _amount = 1000e18;

    vm.startPrank(alice);

    underlyingAsset.mint(alice, _amount);
    _deposit(underlyingAsset, vault, _amount, alice);

    vault.approve(address(twabDelegator), type(uint256).max);

    vm.expectEmit();
    emit VaultSharesStaked(bob, _amount);

    twabDelegator.stake(bob, _amount);

    assertEq(vault.balanceOf(alice), 0);
    assertEq(vault.balanceOf(address(twabDelegator)), _amount);
    assertEq(twabDelegator.balanceOf(alice), 0);
    assertEq(twabDelegator.balanceOf(bob), _amount);

    vm.stopPrank();
  }

  function testStakeZeroAddress() public {
    uint256 _amount = 1000e18;

    vm.startPrank(alice);

    underlyingAsset.mint(alice, _amount);
    _deposit(underlyingAsset, vault, _amount, alice);

    vault.approve(address(twabDelegator), type(uint256).max);

    vm.expectRevert(bytes("ERC20: mint to the zero address"));

    twabDelegator.stake(address(0), _amount);

    vm.stopPrank();
  }

  function testStakeZeroAmount() public {
    vm.startPrank(alice);

    vm.expectRevert(bytes("TD/amount-gt-zero"));
    twabDelegator.stake(alice, 0);

    vm.stopPrank();
  }

  /* ============ Unstake ============ */

  function testUnstake() public {
    uint256 _amount = 1000e18;

    vm.startPrank(alice);

    underlyingAsset.mint(alice, _amount);
    _deposit(underlyingAsset, vault, _amount, alice);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.stake(alice, _amount);

    vm.expectEmit();
    emit VaultSharesUnstaked(alice, alice, _amount);

    twabDelegator.unstake(alice, _amount);

    assertEq(vault.balanceOf(alice), _amount);

    vm.stopPrank();
  }

  function testUnstakeTransferToOther() public {
    uint256 _amount = 1000e18;

    vm.startPrank(alice);

    underlyingAsset.mint(alice, _amount);
    _deposit(underlyingAsset, vault, _amount, alice);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.stake(alice, _amount);

    vm.expectEmit();
    emit VaultSharesUnstaked(alice, bob, _amount);

    twabDelegator.unstake(bob, _amount);

    assertEq(vault.balanceOf(alice), 0);
    assertEq(vault.balanceOf(bob), _amount);

    vm.stopPrank();
  }

  function testUnstakeNoStake() public {
    vm.startPrank(alice);

    vm.expectRevert(bytes("ERC20: burn amount exceeds balance"));
    twabDelegator.unstake(alice, 1000e18);

    vm.stopPrank();
  }

  function testUnstakeZeroAddress() public {
    vm.startPrank(alice);

    vm.expectRevert(bytes("TD/to-not-zero-addr"));
    twabDelegator.unstake(address(0), 1000e18);

    vm.stopPrank();
  }

  function testUnstakeZeroAmount() public {
    vm.startPrank(alice);

    vm.expectRevert(bytes("TD/amount-gt-zero"));
    twabDelegator.unstake(alice, 0);

    vm.stopPrank();
  }

  function testUnstakeAmountGTStake() public {
    uint256 _amount = 1000e18;

    vm.startPrank(alice);

    underlyingAsset.mint(alice, _amount);
    _deposit(underlyingAsset, vault, _amount, alice);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.stake(alice, _amount);

    vm.expectRevert(bytes("ERC20: burn amount exceeds balance"));
    twabDelegator.unstake(alice, 1500e18);

    vm.stopPrank();
  }

  /* ============ Create Delegation ============ */

  function testCreateDelegation() public {
    uint256 _amount = 1000e18;

    vm.startPrank(alice);

    underlyingAsset.mint(alice, _amount);
    _deposit(underlyingAsset, vault, _amount, alice);

    vault.approve(address(twabDelegator), type(uint256).max);

    Delegation _delegation = _computeDelegationAddress(twabDelegator, alice, 0);

    vm.expectEmit();
    emit DelegationCreated(alice, 0, _maxExpiry(), bob, _delegation, alice);

    twabDelegator.createDelegation(alice, 0, bob, MAX_EXPIRY);

    assertEq(twabDelegator.balanceOf(alice), 0);
    assertEq(vault.balanceOf(address(twabDelegator)), 0);

    assertEq(vault.balanceOf(alice), _amount);
    assertEq(twabController.delegateBalanceOf(address(vault), alice), _amount);

    assertEq(vault.balanceOf(bob), 0);
    assertEq(twabController.delegateBalanceOf(address(vault), bob), 0);

    assertEq(_delegation.lockUntil(), _maxExpiry());

    assertEq(vault.balanceOf(address(_delegation)), 0);
    assertEq(twabController.delegateOf(address(vault), address(_delegation)), bob);

    vm.stopPrank();
  }

  function testCreateDelegationSlotAlreadyUsed() public {
    vm.startPrank(alice);

    twabDelegator.createDelegation(alice, 0, bob, MAX_EXPIRY);

    vm.expectRevert("ERC1167: create2 failed");
    twabDelegator.createDelegation(alice, 0, bob, MAX_EXPIRY);

    vm.stopPrank();
  }

  function testCreateDelegationZeroAddressDelegator() public {
    vm.startPrank(alice);

    vm.expectRevert("TD/not-dlgtr-or-rep");
    twabDelegator.createDelegation(address(0), 0, bob, MAX_EXPIRY);

    vm.stopPrank();
  }

  function testCreateDelegationZeroAddressDelegatee() public {
    vm.startPrank(alice);

    vm.expectRevert("TD/dlgt-not-zero-addr");
    twabDelegator.createDelegation(alice, 0, address(0), MAX_EXPIRY);

    vm.stopPrank();
  }

  function testCreateDelegationExpiryGTMax() public {
    vm.startPrank(alice);

    vm.expectRevert("TD/lock-too-long");
    twabDelegator.createDelegation(alice, 0, bob, MAX_EXPIRY + 1);

    vm.stopPrank();
  }

  /* ============ Update Delegatee ============ */

  function testUpdateDelegatee() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    Delegation _delegation = twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    assertEq(twabDelegator.balanceOf(owner), 0);

    assertEq(twabController.delegateOf(address(vault), address(_delegation)), alice);

    assertEq(vault.balanceOf(address(_delegation)), _amount);
    assertEq(vault.balanceOf(alice), 0);

    assertEq(twabController.delegateBalanceOf(address(vault), address(_delegation)), 0);
    assertEq(twabController.delegateBalanceOf(address(vault), alice), _amount);

    vm.warp(MAX_EXPIRY + 1);

    vm.expectEmit();
    emit DelegateeUpdated(owner, 0, bob, uint96(block.timestamp), owner);

    twabDelegator.updateDelegatee(owner, 0, bob, 0);

    assertEq(twabController.delegateBalanceOf(address(vault), alice), 0);
    assertEq(twabController.delegateBalanceOf(address(vault), bob), _amount);

    assertEq(vault.balanceOf(address(twabDelegator)), 0);
    assertEq(vault.balanceOf(address(_delegation)), _amount);
    assertEq(twabController.delegateOf(address(vault), address(_delegation)), bob);

    vm.stopPrank();
  }

  function testUpdateDelegateeByRepresentative() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    Delegation _delegation = twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    assertEq(twabDelegator.balanceOf(owner), 0);

    assertEq(twabController.delegateOf(address(vault), address(_delegation)), alice);

    assertEq(vault.balanceOf(address(_delegation)), _amount);
    assertEq(vault.balanceOf(alice), 0);

    assertEq(twabController.delegateBalanceOf(address(vault), address(_delegation)), 0);
    assertEq(twabController.delegateBalanceOf(address(vault), alice), _amount);

    vm.warp(MAX_EXPIRY + 1);

    vm.expectEmit();
    emit RepresentativeSet(owner, representative, true);

    twabDelegator.setRepresentative(representative, true);

    vm.stopPrank();

    vm.startPrank(representative);

    vm.expectEmit();
    emit DelegateeUpdated(owner, 0, bob, uint96(block.timestamp), representative);

    twabDelegator.updateDelegatee(owner, 0, bob, 0);

    assertEq(twabController.delegateBalanceOf(address(vault), alice), 0);
    assertEq(twabController.delegateBalanceOf(address(vault), bob), _amount);

    assertEq(vault.balanceOf(address(twabDelegator)), 0);
    assertEq(vault.balanceOf(address(_delegation)), _amount);
    assertEq(twabController.delegateOf(address(vault), address(_delegation)), bob);

    vm.stopPrank();
  }

  function testUpdateDelegateeLockDuration() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    Delegation _delegation = twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    assertEq(twabDelegator.balanceOf(owner), 0);

    assertEq(twabController.delegateOf(address(vault), address(_delegation)), alice);

    assertEq(vault.balanceOf(address(_delegation)), _amount);
    assertEq(vault.balanceOf(alice), 0);

    assertEq(twabController.delegateBalanceOf(address(vault), address(_delegation)), 0);
    assertEq(twabController.delegateBalanceOf(address(vault), alice), _amount);

    vm.warp(MAX_EXPIRY + 1);

    vm.expectEmit();
    emit DelegateeUpdated(owner, 0, bob, _maxExpiry(), owner);

    twabDelegator.updateDelegatee(owner, 0, bob, MAX_EXPIRY);

    assertEq(_delegation.lockUntil(), _maxExpiry());

    vm.stopPrank();
  }

  function testUpdateDelegateeWithdrawDelegation() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    Delegation _delegation = twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    assertEq(twabDelegator.balanceOf(owner), 0);

    assertEq(twabController.delegateOf(address(vault), address(_delegation)), alice);

    assertEq(vault.balanceOf(address(_delegation)), _amount);
    assertEq(vault.balanceOf(alice), 0);

    assertEq(twabController.delegateBalanceOf(address(vault), address(_delegation)), 0);
    assertEq(twabController.delegateBalanceOf(address(vault), alice), _amount);

    vm.warp(MAX_EXPIRY + 1);

    twabDelegator.updateDelegatee(owner, 0, bob, 0);

    vm.expectEmit();
    emit WithdrewDelegationToStake(owner, 0, _amount, owner);

    twabDelegator.withdrawDelegationToStake(owner, 0, _amount);

    assertEq(vault.balanceOf(alice), 0);
    assertEq(vault.balanceOf(bob), 0);

    assertEq(twabController.delegateBalanceOf(address(vault), alice), 0);
    assertEq(twabController.delegateBalanceOf(address(vault), bob), 0);

    assertEq(twabDelegator.balanceOf(owner), _amount);
    assertEq(vault.balanceOf(address(twabDelegator)), _amount);
    assertEq(vault.balanceOf(address(_delegation)), 0);

    vm.stopPrank();
  }

  function testUpdateDelegateeNotDelegator() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vm.warp(MAX_EXPIRY + 1);

    vm.stopPrank();

    vm.startPrank(bob);

    vm.expectRevert(bytes("TD/not-dlgtr-or-rep"));
    twabDelegator.updateDelegatee(owner, 0, bob, 0);

    vm.stopPrank();
  }

  function testUpdateDelegateeZeroAddress() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vm.warp(MAX_EXPIRY + 1);

    vm.expectRevert(bytes("TD/dlgt-not-zero-addr"));
    twabDelegator.updateDelegatee(owner, 0, address(0), 0);

    vm.stopPrank();
  }

  function testUpdateDelegateeInexistentDelegation() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vm.warp(MAX_EXPIRY + 1);

    vm.expectRevert();
    twabDelegator.updateDelegatee(owner, 1, bob, 0);

    vm.stopPrank();
  }

  function testUpdateDelegateeDelegationLocked() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vm.expectRevert(bytes("TD/delegation-locked"));
    twabDelegator.updateDelegatee(owner, 0, bob, 0);

    vm.stopPrank();
  }

  /* ============ Fund Delegation ============ */

  function testFundDelegation() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    Delegation _delegation = twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    assertEq(vault.balanceOf(address(_delegation)), 0);

    vm.stopPrank();

    vm.startPrank(bob);

    underlyingAsset.mint(bob, _amount);
    _deposit(underlyingAsset, vault, _amount, bob);

    vault.approve(address(twabDelegator), type(uint256).max);

    vm.expectEmit();
    emit DelegationFunded(owner, 0, _amount, bob);

    twabDelegator.fundDelegation(owner, 0, _amount);

    assertEq(vault.balanceOf(alice), 0);
    assertEq(vault.balanceOf(address(twabDelegator)), 0);
    assertEq(vault.balanceOf(address(_delegation)), _amount);

    assertEq(twabController.delegateOf(address(vault), address(_delegation)), alice);
    assertEq(twabController.delegateBalanceOf(address(vault), alice), _amount);

    assertEq(twabDelegator.balanceOf(owner), 0);
    assertEq(twabDelegator.balanceOf(bob), 0);

    vm.stopPrank();
  }

  function testFundDelegationBeforeCreation() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);

    vm.expectEmit();
    emit DelegationFunded(owner, 0, _amount, owner);

    twabDelegator.fundDelegation(owner, 0, _amount);

    Delegation _delegation = twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    assertEq(vault.balanceOf(alice), 0);
    assertEq(vault.balanceOf(address(twabDelegator)), 0);
    assertEq(vault.balanceOf(address(_delegation)), _amount);

    assertEq(twabController.delegateOf(address(vault), address(_delegation)), alice);
    assertEq(twabController.delegateBalanceOf(address(vault), alice), _amount);

    assertEq(twabDelegator.balanceOf(owner), 0);

    vm.stopPrank();
  }

  function testFundDelegationZeroAddress() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vm.expectRevert(bytes("TD/dlgtr-not-zero-adr"));
    twabDelegator.fundDelegation(address(0), 0, _amount);

    vm.stopPrank();
  }

  function testFundDelegationZeroAmount() public {
    vm.startPrank(owner);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vm.expectRevert(bytes("TD/amount-gt-zero"));
    twabDelegator.fundDelegation(owner, 0, 0);

    vm.stopPrank();
  }

  /* ============ Fund Delegation from Stake ============ */

  function testFundDelegationFromStake() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    Delegation _delegation = twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    assertEq(vault.balanceOf(address(_delegation)), 0);

    vault.approve(address(twabDelegator), type(uint256).max);

    vm.expectEmit();
    emit DelegationFundedFromStake(owner, 0, _amount, owner);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    assertEq(vault.balanceOf(alice), 0);
    assertEq(vault.balanceOf(address(twabDelegator)), 0);
    assertEq(vault.balanceOf(address(_delegation)), _amount);

    assertEq(twabController.delegateOf(address(vault), address(_delegation)), alice);
    assertEq(twabController.delegateBalanceOf(address(vault), alice), _amount);

    assertEq(twabDelegator.balanceOf(owner), 0);
    assertEq(twabDelegator.balanceOf(bob), 0);

    vm.stopPrank();
  }

  function testFundDelegationFromStakeByRepresentative() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    Delegation _delegation = twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    twabDelegator.setRepresentative(representative, true);

    vm.stopPrank();

    vm.startPrank(representative);

    assertEq(vault.balanceOf(address(_delegation)), 0);

    vm.expectEmit();
    emit DelegationFundedFromStake(owner, 0, _amount, representative);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    assertEq(vault.balanceOf(alice), 0);
    assertEq(vault.balanceOf(address(twabDelegator)), 0);
    assertEq(vault.balanceOf(address(_delegation)), _amount);

    assertEq(twabController.delegateOf(address(vault), address(_delegation)), alice);
    assertEq(twabController.delegateBalanceOf(address(vault), alice), _amount);

    assertEq(twabDelegator.balanceOf(owner), 0);

    vm.stopPrank();
  }

  function testFundDelegationFromStakeBeforeCreation() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    vault.approve(address(twabDelegator), type(uint256).max);

    vm.expectEmit();
    emit DelegationFundedFromStake(owner, 0, _amount, owner);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    Delegation _delegation = twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    assertEq(vault.balanceOf(alice), 0);
    assertEq(vault.balanceOf(address(twabDelegator)), 0);
    assertEq(vault.balanceOf(address(_delegation)), _amount);

    assertEq(twabController.delegateOf(address(vault), address(_delegation)), alice);
    assertEq(twabController.delegateBalanceOf(address(vault), alice), _amount);

    assertEq(twabDelegator.balanceOf(owner), 0);
    assertEq(twabDelegator.balanceOf(bob), 0);

    vm.stopPrank();
  }

  function testFundDelegationFromStakeNotRepresentative() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    twabDelegator.setRepresentative(representative, true);

    vm.stopPrank();

    vm.startPrank(bob);

    vm.expectRevert(bytes("TD/not-dlgtr-or-rep"));
    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    vm.stopPrank();
  }

  function testFundDelegationFromStakeZeroAmount() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vm.expectRevert(bytes("TD/amount-gt-zero"));
    twabDelegator.fundDelegationFromStake(owner, 0, 0);

    vm.stopPrank();
  }

  function testFundDelegationFromStakeAmountGTStake() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vm.expectRevert(bytes("ERC20: burn amount exceeds balance"));
    twabDelegator.fundDelegationFromStake(owner, 0, _amount * 2);

    vm.stopPrank();
  }

  /* ============ Withdraw Delegation to Stake ============ */

  function testWithdrawDelegationToStake() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    Delegation _delegation = twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    assertEq(twabDelegator.balanceOf(owner), 0);

    vm.warp(MAX_EXPIRY + 1);

    vm.expectEmit();
    emit WithdrewDelegationToStake(owner, 0, _amount, owner);

    twabDelegator.withdrawDelegationToStake(owner, 0, _amount);

    assertEq(twabDelegator.balanceOf(owner), _amount);
    assertEq(vault.balanceOf(address(twabDelegator)), _amount);

    assertEq(vault.balanceOf(alice), 0);
    assertEq(vault.balanceOf(address(_delegation)), 0);

    assertEq(twabController.delegateOf(address(vault), address(_delegation)), alice);
    assertEq(twabController.delegateBalanceOf(address(vault), alice), 0);

    vm.stopPrank();
  }

  function testWithdrawDelegationToStakeByRepresentative() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    Delegation _delegation = twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    assertEq(twabDelegator.balanceOf(owner), 0);

    twabDelegator.setRepresentative(representative, true);

    vm.stopPrank();

    vm.startPrank(representative);

    vm.warp(MAX_EXPIRY + 1);

    vm.expectEmit();
    emit WithdrewDelegationToStake(owner, 0, _amount, representative);

    twabDelegator.withdrawDelegationToStake(owner, 0, _amount);

    assertEq(twabDelegator.balanceOf(owner), _amount);
    assertEq(vault.balanceOf(address(twabDelegator)), _amount);

    assertEq(vault.balanceOf(alice), 0);
    assertEq(vault.balanceOf(address(_delegation)), 0);

    assertEq(twabController.delegateOf(address(vault), address(_delegation)), alice);
    assertEq(twabController.delegateBalanceOf(address(vault), alice), 0);

    vm.stopPrank();
  }

  function testWithdrawDelegationToStakeZeroAmount() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    vm.warp(MAX_EXPIRY + 1);

    vm.expectRevert(bytes("TD/amount-gt-zero"));
    twabDelegator.withdrawDelegationToStake(owner, 0, 0);

    vm.stopPrank();
  }

  function testWithdrawDelegationToStakeNotRepresentative() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    twabDelegator.setRepresentative(representative, true);

    vm.stopPrank();

    vm.startPrank(bob);

    vm.warp(MAX_EXPIRY + 1);

    vm.expectRevert(bytes("TD/not-dlgtr-or-rep"));
    twabDelegator.withdrawDelegationToStake(owner, 0, _amount);

    vm.stopPrank();
  }

  function testWithdrawDelegationToStakeInexistentDelegation() public {
    vm.startPrank(owner);

    vm.expectRevert();
    twabDelegator.withdrawDelegationToStake(owner, 0, 1000e18);

    vm.stopPrank();
  }

  function testWithdrawDelegationToStakeDelegationLocked() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    vm.expectRevert(bytes("TD/delegation-locked"));
    twabDelegator.withdrawDelegationToStake(owner, 0, _amount);

    vm.stopPrank();
  }

  /* ============ Transfer Delegation ============ */

  function testTransferDelegation() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    Delegation _delegation = twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    vm.warp(MAX_EXPIRY + 1);

    vm.expectEmit();
    emit TransferredDelegation(owner, 0, _amount, bob);

    twabDelegator.transferDelegationTo(0, _amount, bob);

    assertEq(twabDelegator.balanceOf(owner), 0);
    assertEq(vault.balanceOf(address(twabDelegator)), 0);

    assertEq(vault.balanceOf(address(_delegation)), 0);
    assertEq(twabController.delegateOf(address(vault), address(_delegation)), alice);

    assertEq(vault.balanceOf(alice), 0);
    assertEq(twabController.delegateBalanceOf(address(vault), alice), 0);

    assertEq(vault.balanceOf(bob), _amount);
    assertEq(twabController.delegateBalanceOf(address(vault), bob), _amount);

    vm.stopPrank();
  }

  function testTransferDelegationToUser() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    Delegation _delegation = twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    vm.warp(MAX_EXPIRY + 1);

    vm.expectEmit();
    emit TransferredDelegation(owner, 0, _amount, bob);

    twabDelegator.transferDelegationTo(0, _amount, bob);

    assertEq(twabDelegator.balanceOf(owner), 0);
    assertEq(vault.balanceOf(address(twabDelegator)), 0);

    assertEq(vault.balanceOf(address(_delegation)), 0);
    assertEq(twabController.delegateOf(address(vault), address(_delegation)), alice);

    assertEq(vault.balanceOf(alice), 0);
    assertEq(twabController.delegateBalanceOf(address(vault), alice), 0);

    assertEq(vault.balanceOf(bob), _amount);
    assertEq(twabController.delegateBalanceOf(address(vault), bob), _amount);

    vm.stopPrank();
  }

  function testTransferDelegationRepresentativeNotAllowed() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);
    twabDelegator.setRepresentative(representative, true);

    vm.stopPrank();

    vm.startPrank(representative);

    vm.warp(MAX_EXPIRY + 1);

    vm.expectRevert();

    twabDelegator.transferDelegationTo(0, _amount, bob);

    vm.stopPrank();
  }

  function testTransferDelegationOnlyOwner() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    vm.stopPrank();

    vm.startPrank(bob);

    vm.warp(MAX_EXPIRY + 1);

    vm.expectRevert();

    twabDelegator.transferDelegationTo(0, _amount, bob);

    vm.stopPrank();
  }

  function testTransferDelegationZeroAmount() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    vm.warp(MAX_EXPIRY + 1);

    vm.expectRevert(bytes("TD/amount-gt-zero"));

    twabDelegator.transferDelegationTo(0, 0, bob);

    vm.stopPrank();
  }

  function testTransferDelegationNonExistent() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    vm.expectRevert();
    twabDelegator.transferDelegationTo(0, _amount, alice);

    vm.stopPrank();
  }

  function testTransferDelegationLocked() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    vm.expectRevert(bytes("TD/delegation-locked"));
    twabDelegator.transferDelegationTo(0, _amount, bob);

    vm.stopPrank();
  }

  /* ============ Transfer Delegation ============ */

  function testRepresentativeSet() public {
    vm.startPrank(owner);

    vm.expectEmit();
    emit RepresentativeSet(owner, representative, true);

    twabDelegator.setRepresentative(representative, true);

    assertEq(twabDelegator.isRepresentativeOf(owner, representative), true);

    vm.stopPrank();
  }

  function testRepresentativeUnset() public {
    vm.startPrank(owner);

    twabDelegator.setRepresentative(representative, true);

    vm.expectEmit();
    emit RepresentativeSet(owner, representative, false);

    twabDelegator.setRepresentative(representative, false);

    assertEq(twabDelegator.isRepresentativeOf(owner, representative), false);

    vm.stopPrank();
  }

  function testRepresentativeZeroAddress() public {
    vm.startPrank(owner);

    vm.expectRevert(bytes("TD/rep-not-zero-addr"));
    twabDelegator.setRepresentative(address(0), true);

    vm.stopPrank();
  }

  /* ============ Multicall ============ */

  function testMulticall() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);

    Delegation _delegation = _computeDelegationAddress(twabDelegator, owner, 0);

    bytes[] memory _data = new bytes[](1);

    _data[0] = abi.encodeWithSelector(
      bytes4(keccak256("stake(address,uint256)")),
      owner,
      _amount,
      bytes4(keccak256("createDelegation(address,uint256,address,uint96)")),
      owner,
      0,
      alice,
      MAX_EXPIRY
    );

    vm.expectEmit();
    emit VaultSharesStaked(owner, _amount);
    emit DelegationCreated(owner, 0, _maxExpiry(), alice, _delegation, owner);

    twabDelegator.multicall(_data);

    vm.stopPrank();
  }

  function testPermitAndMulticall() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);

    Delegation _delegation = _computeDelegationAddress(twabDelegator, owner, 0);

    bytes[] memory _data = new bytes[](1);

    _data[0] = abi.encodeWithSelector(
      bytes4(keccak256("stake(address,uint256)")),
      owner,
      _amount,
      bytes4(keccak256("createDelegation(address,uint256,address,uint96)")),
      owner,
      0,
      alice,
      MAX_EXPIRY
    );

    (uint8 _v, bytes32 _r, bytes32 _s) = _signPermit(
      vault,
      twabDelegator,
      _amount,
      owner,
      ownerPrivateKey
    );

    vm.expectEmit();
    emit VaultSharesStaked(owner, _amount);
    emit DelegationCreated(owner, 0, _maxExpiry(), alice, _delegation, owner);

    twabDelegator.permitAndMulticall(
      _amount,
      PermitAndMulticall.Signature({ deadline: block.timestamp, v: _v, r: _r, s: _s }),
      _data
    );

    vm.stopPrank();
  }

  /* ============ Getters ============ */

  function testGetDelegation() public {
    uint256 _amount = 1000e18;

    vm.startPrank(owner);

    underlyingAsset.mint(owner, _amount);
    _deposit(underlyingAsset, vault, _amount, owner);

    vault.approve(address(twabDelegator), type(uint256).max);
    twabDelegator.stake(owner, _amount);

    twabDelegator.createDelegation(owner, 0, alice, MAX_EXPIRY);

    vault.approve(address(twabDelegator), type(uint256).max);

    twabDelegator.fundDelegationFromStake(owner, 0, _amount);

    vm.stopPrank();

    address _delegationAddress = twabDelegator.computeDelegationAddress(owner, 0);

    (
      Delegation _delegation,
      address _delegatee,
      uint256 _balance,
      uint256 _lockUntil,
      bool _wasCreated
    ) = twabDelegator.getDelegation(owner, 0);

    assertEq(address(_delegation), _delegationAddress);
    assertEq(_delegatee, alice);
    assertEq(_balance, _amount);
    assertEq(_lockUntil, _maxExpiry());
    assertEq(_wasCreated, true);
  }

  function testGetDelegationEmpty() public {
    address _delegationAddress = twabDelegator.computeDelegationAddress(owner, 0);

    (
      Delegation _delegation,
      address _delegatee,
      uint256 _balance,
      uint256 _lockUntil,
      bool _wasCreated
    ) = twabDelegator.getDelegation(owner, 0);

    assertEq(address(_delegation), _delegationAddress);
    assertEq(_delegatee, _delegationAddress);
    assertEq(_balance, 0);
    assertEq(_lockUntil, 0);
    assertEq(_wasCreated, false);
  }

  function testGetDecimals() public {
    assertEq(twabDelegator.decimals(), vault.decimals());
  }

  function testGetTwabController() public {
    assertEq(twabDelegator.twabController(), address(twabController));
  }

  function testGetVault() public {
    assertEq(twabDelegator.vault(), address(vault));
  }
}
