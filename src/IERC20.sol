// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IERC20
/// @notice The ERC-20 surface Handshake implements and TimeoutEscrow consumes.
/// @dev Declared locally so the project vendors no token library. `transfer` and `transferFrom`
/// are declared as returning `bool`; TimeoutEscrow additionally tolerates tokens that return
/// nothing, so it stays usable with non-compliant ERC-20s if one is ever paired with it.
interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
