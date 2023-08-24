// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";

import { Clones } from "openzeppelin/proxy/Clones.sol";
import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { IERC20Permit } from "openzeppelin/token/ERC20/extensions/ERC20Permit.sol";

import { Vault } from "pt-v5-vault/Vault.sol";

import { Delegation } from "../../src/Delegation.sol";
import { TwabDelegator } from "../../src/TwabDelegator.sol";

contract Helpers is Test {
  using Clones for address;

  /* ============ Variables ============ */
  uint96 public constant MAX_EXPIRY = 15552000; // 180 days

  bytes32 private constant _PERMIT_TYPEHASH =
    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

  /* ============ Permit ============ */
  function _signPermit(
    Vault _vault,
    TwabDelegator _twabDelegator,
    uint256 _assets,
    address _owner,
    uint256 _ownerPrivateKey
  ) internal view returns (uint8 _v, bytes32 _r, bytes32 _s) {
    uint256 _nonce = IERC20Permit(address(_vault)).nonces(_owner);

    (_v, _r, _s) = vm.sign(
      _ownerPrivateKey,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          IERC20Permit(address(_vault)).DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              _PERMIT_TYPEHASH,
              _owner,
              address(_twabDelegator),
              _assets,
              _nonce,
              block.timestamp
            )
          )
        )
      )
    );
  }

  /* ============ Deposit ============ */
  function _deposit(
    IERC20 _underlyingAsset,
    Vault _vault,
    uint256 _assets,
    address _receiver
  ) internal returns (uint256) {
    _underlyingAsset.approve(address(_vault), type(uint256).max);
    return _vault.deposit(_assets, _receiver);
  }

  /* ============ Delegation ============ */
  function _computeDelegationAddress(
    TwabDelegator _twabDelegator,
    address _delegator,
    uint256 _slot
  ) internal view returns (Delegation) {
    return
      Delegation(
        address(_twabDelegator.delegationInstance()).predictDeterministicAddress(
          keccak256(abi.encodePacked(_delegator, _slot)),
          address(_twabDelegator)
        )
      );
  }

  function _maxExpiry() internal view returns (uint96) {
    return uint96(block.timestamp + MAX_EXPIRY);
  }
}
