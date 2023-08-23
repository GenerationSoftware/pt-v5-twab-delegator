// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { IERC20Permit } from "openzeppelin/token/ERC20/extensions/ERC20Permit.sol";

import { Vault } from "pt-v5-vault/Vault.sol";

contract Helpers is Test {
  /* ============ Variables ============ */
  bytes32 private constant _PERMIT_TYPEHASH =
    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

  uint256 public constant FEE_PRECISION = 1e9;

  uint256 public constant YIELD_FEE_PERCENTAGE = 100000000; // 0.1 = 10%

  /**
   * For a token with 2 decimal places like gUSD, this is the minimum fee percentage that can be taken for a 2 figure yield.
   * This is because Solidity will truncate down the result to 0 since it won't fit in 2 decimal places.
   * i.e. 10 * 0.01% = 10 * 0.0001 = 1000 * 100000 / 1e9 = 0
   */
  uint256 public constant LOW_YIELD_FEE_PERCENTAGE = 1000000; // 0.001 = 0.1%

  /* ============ Permit ============ */
  function _signPermit(
    IERC20Permit _underlyingAsset,
    Vault _vault,
    uint256 _assets,
    address _owner,
    uint256 _ownerPrivateKey
  ) internal view returns (uint8 _v, bytes32 _r, bytes32 _s) {
    uint256 _nonce = _underlyingAsset.nonces(_owner);

    (_v, _r, _s) = vm.sign(
      _ownerPrivateKey,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          _underlyingAsset.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(_PERMIT_TYPEHASH, _owner, address(_vault), _assets, _nonce, block.timestamp)
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

  function _depositWithPermit(
    Vault _vault,
    uint256 _assets,
    address _owner,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) internal returns (uint256) {
    return _vault.depositWithPermit(_assets, _owner, block.timestamp, _v, _r, _s);
  }
}
