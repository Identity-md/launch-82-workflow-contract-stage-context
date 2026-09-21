// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../../src/IERC20.sol";

/// @notice A minimal, well-behaved ERC-20 the hostile mocks below extend.
/// @dev Free minting on purpose: these exist only to drive TimeoutEscrow from tests.
contract MockERC20 is IERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        _spend(from, amount);
        _move(from, to, amount);
        return true;
    }

    function _spend(address from, uint256 amount) internal {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice Re-enters a configured function on the escrow from inside every token movement.
/// @dev Records whether the re-entrant call succeeded so a test can assert the escrow rejected it.
contract ReentrantToken is MockERC20 {
    address public escrow;
    bytes public payload;
    bool public armed;

    uint256 public reentryAttempts;
    bool public lastReentrySucceeded;
    bytes public lastReentryReturn;

    function arm(address escrow_, bytes calldata payload_) external {
        escrow = escrow_;
        payload = payload_;
        armed = true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _reenter();
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _reenter();
        _spend(from, amount);
        _move(from, to, amount);
        return true;
    }

    /// @dev Fires once per arming: without that, the callback recurses until the gas runs out.
    function _reenter() private {
        if (!armed) return;
        armed = false;
        reentryAttempts += 1;
        (bool ok, bytes memory data) = escrow.call(payload);
        lastReentrySucceeded = ok;
        lastReentryReturn = data;
    }
}

/// @notice Returns `false` instead of reverting, the classic silent-failure ERC-20.
contract FalseReturningToken is MockERC20 {
    function transfer(address, uint256) external pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return false;
    }
}

/// @notice Returns no data at all, like the pre-ERC-20 tokens that predate the bool return.
contract NoReturnToken is MockERC20 {
    function transfer(address to, uint256 amount) external override returns (bool) {
        _move(msg.sender, to, amount);
        assembly {
            return(0, 0)
        }
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _spend(from, amount);
        _move(from, to, amount);
        assembly {
            return(0, 0)
        }
    }
}

/// @notice Reverts on every movement.
contract RevertingToken is MockERC20 {
    function transfer(address, uint256) external pure override returns (bool) {
        revert("nope");
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        revert("nope");
    }
}
