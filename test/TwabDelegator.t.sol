// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { console2 } from "forge-std/console2.sol";

import { ERC4626Mock, IERC20, IERC20Metadata } from "openzeppelin/mocks/ERC4626Mock.sol";

import { TwabController } from "pt-v5-twab-controller/TwabController.sol";
import { ERC20, PrizePool, Vault } from "pt-v5-vault/Vault.sol";

import { ERC20PermitMock } from "./contracts/mock/ERC20PermitMock.sol";

import { TwabDelegator } from "../src/TwabDelegator.sol";

import { Helpers } from "./utils/Helpers.t.sol";

contract TwabDelegatorTest is Helpers {
  /* ============ Events ============ */
  event TwabControllerSet(TwabController indexed twabController);

  event VaultSet(Vault indexed vault);

  event VaultSharesStaked(address indexed delegator, uint256 amount);

  /* ============ Variables ============ */
  address public owner;
  uint256 public ownerPrivateKey;

  address public manager;
  uint256 public managerPrivateKey;

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
    (manager, managerPrivateKey) = makeAddrAndKey("Manager");
    (alice, alicePrivateKey) = makeAddrAndKey("Alice");
    (bob, bobPrivateKey) = makeAddrAndKey("Bob");

    underlyingAsset = new ERC20PermitMock("Dai Stablecoin");
    prizeToken = new ERC20PermitMock("PoolTogether");

    twabController = new TwabController(1 days, uint32(block.timestamp));

    prizePool = PrizePool(address(0x8C66F3693f99b2582630405e07A8054AD842DD5A));

    claimer = address(0xe291d9169F0316272482dD82bF297BB0a11D267f);

    yieldVault = new ERC4626Mock(address(underlyingAsset));

    vault = new Vault(
      underlyingAsset,
      vaultName,
      vaultSymbol,
      twabController,
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
    emit VaultSharesStaked(address(alice), _amount);

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
    emit VaultSharesStaked(address(bob), _amount);

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
    uint256 _amount = 1000e18;

    vm.startPrank(alice);

    underlyingAsset.mint(alice, _amount);
    _deposit(underlyingAsset, vault, _amount, alice);

    vault.approve(address(twabDelegator), type(uint256).max);

    vm.expectRevert(bytes("TD/amount-gt-zero"));

    twabDelegator.stake(alice, 0);

    vm.stopPrank();
  }
}
