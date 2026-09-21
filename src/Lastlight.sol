// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./IERC20.sol";

/// @title Lastlight (LAST)
/// @notice Fixed-supply ERC-20 reward token for the Lastlight protocol.
/// @dev The whole supply — exactly 1,000,000,000 LAST, i.e. 10^27 minor units at 18 decimals — is
/// minted once, in the constructor, to `msg.sender`. Under ProjectFactory that sender is the factory,
/// which then splits the supply according to launch policy. There is no owner, no mint, no burn, no
/// pause and no upgrade path: the supply observed at launch is the supply forever.
contract Lastlight is IERC20 {
    string public constant name = "Lastlight";
    string public constant symbol = "LAST";
    uint8 public constant decimals = 18;

    /// @notice 1,000,000,000 LAST in minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    error InvalidReceiver();
    error InvalidSpender();
    error InsufficientBalance(uint256 available, uint256 required);
    error InsufficientAllowance(uint256 available, uint256 required);

    constructor() {
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc IERC20
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @inheritdoc IERC20
    function approve(address spender, uint256 value) external returns (bool) {
        if (spender == address(0)) revert InvalidSpender();
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /// @inheritdoc IERC20
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @inheritdoc IERC20
    /// @dev An allowance of `type(uint256).max` is treated as unlimited and is never decremented.
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 current = allowance[from][msg.sender];
        if (current != type(uint256).max) {
            if (current < value) revert InsufficientAllowance(current, value);
            unchecked {
                allowance[from][msg.sender] = current - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (to == address(0)) revert InvalidReceiver();
        uint256 available = balanceOf[from];
        if (available < value) revert InsufficientBalance(available, value);
        unchecked {
            balanceOf[from] = available - value;
            // Sum of balances never exceeds TOTAL_SUPPLY, so this cannot overflow.
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
