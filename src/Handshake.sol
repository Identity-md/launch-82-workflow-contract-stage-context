// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./IERC20.sol";

/// @title Handshake (SHAKE)
/// @notice The fixed-supply launch token of the Handshake protocol.
/// @dev Deliberately minimal and final:
///      - zero-argument constructor, so the launch factory can deploy it with no configuration;
///      - the entire supply (1,000,000,000 SHAKE = 10^27 minor units) is minted once, in the
///        constructor, to `msg.sender` — the deployer, which at launch is the factory;
///      - there is no mint, burn-and-remint, owner, minter, pause, initializer or upgrade path,
///        so `totalSupply()` can never change after deployment;
///      - no DELEGATECALL, CALLCODE or SELFDESTRUCT: the deployed behaviour is the final behaviour;
///      - no transfer fee, no rebase, no blocklist: a transfer of `n` moves exactly `n`.
contract Handshake is IERC20 {
    /// @notice Thrown when a transfer or approval would involve the zero address.
    error ZeroAddress();
    /// @notice Thrown when an account transfers more than it holds.
    error InsufficientBalance(address account, uint256 balance, uint256 needed);
    /// @notice Thrown when a spender moves more than it was approved for.
    error InsufficientAllowance(address owner, address spender, uint256 allowed, uint256 needed);

    string public constant name = "Handshake";
    string public constant symbol = "SHAKE";
    uint8 public constant decimals = 18;

    /// @notice The whole supply, minted in the constructor and immutable thereafter.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    constructor() {
        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    /// @notice Move `amount` from the caller to `to`.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Let `spender` move up to `amount` of the caller's balance.
    /// @dev Plain ERC-20 overwrite semantics. Callers changing a live non-zero allowance should be
    ///      aware of the classic approve front-running race and set it to zero first if it matters.
    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Move `amount` from `from` to `to` using the caller's allowance.
    /// @dev The allowance is always decremented, including when it is `type(uint256).max`: an
    ///      "infinite" approval is not treated specially, so the accounting has no exception in it.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance(from, msg.sender, allowed, amount);
        unchecked {
            allowance[from][msg.sender] = allowed - amount;
        }
        emit Approval(from, msg.sender, allowed - amount);
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance(from, balance, amount);
        unchecked {
            balanceOf[from] = balance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
