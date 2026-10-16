// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title SwarmCore (SWARMCORE)
/// @notice A fixed-supply ERC-20 token. The whole supply of 1,000,000,000 SWARMCORE (18 decimals) is
/// minted once, in the constructor, to the deployer. Nothing can mint afterwards.
/// @dev Deliberately minimal and self-contained:
/// - no owner, no admin role, no pause, no blocklist, no fee and no burn: every transfer moves exactly
///   the amount asked for, and nobody but a holder can move or freeze that holder's balance;
/// - no external calls, no delegatecall, no selfdestruct, no upgradeability;
/// - the constructor takes no arguments and calls no other contract, so the launch factory can deploy
///   it on an empty chain and receives the whole supply as `msg.sender`;
/// - an allowance of `type(uint256).max` is treated as unlimited and is not decremented;
/// - errors follow the ERC-6093 names used by OpenZeppelin v5 so tooling recognises them.
contract SwarmCore {
    /// @notice Emitted when `value` tokens move from `from` to `to`, including the single mint at deployment.
    event Transfer(address indexed from, address indexed to, uint256 value);
    /// @notice Emitted when `owner` sets the allowance of `spender` to `value`.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice A transfer asked for more than the sender holds.
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    /// @notice A transfer to the zero address, which would destroy tokens.
    error ERC20InvalidReceiver(address receiver);
    /// @notice A `transferFrom` for more than the caller is allowed to spend.
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    /// @notice An approval of the zero address as spender.
    error ERC20InvalidSpender(address spender);

    /// @notice The number of decimals the token uses.
    uint8 public constant DECIMALS = 18;

    /// @notice The fixed total supply in minor units: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    /// @notice Mints the whole fixed supply to the deployer, once.
    constructor() {
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    /// @notice The token's name.
    function name() external pure returns (string memory) {
        return "SwarmCore";
    }

    /// @notice The token's symbol.
    function symbol() external pure returns (string memory) {
        return "SWARMCORE";
    }

    /// @notice The number of decimals the token uses.
    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    /// @notice The total supply, which never changes after deployment.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @notice The balance of `account`.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice The remaining amount `spender` may transfer on behalf of `owner`.
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @notice Moves `value` tokens from the caller to `to`.
    /// @return True on success. Reverts, rather than returning false, on every failure.
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @notice Sets the allowance of `spender` over the caller's tokens to `value`.
    /// @dev This is the plain ERC-20 `approve`. To change a non-zero allowance safely, set it to zero
    /// first, or rely on the spender's own accounting.
    /// @return True on success.
    function approve(address spender, uint256 value) external returns (bool) {
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /// @notice Moves `value` tokens from `from` to `to` using the caller's allowance.
    /// @dev An allowance of `type(uint256).max` is unlimited and is not reduced.
    /// @return True on success. Reverts, rather than returning false, on every failure.
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        unchecked {
            // The subtraction cannot underflow: `value <= fromBalance` was checked above. The addition
            // cannot overflow: the sum of all balances is always exactly TOTAL_SUPPLY.
            _balances[from] = fromBalance - value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) private {
        uint256 current = _allowances[owner][spender];
        if (current == type(uint256).max) return;
        if (current < value) revert ERC20InsufficientAllowance(spender, current, value);
        unchecked {
            _allowances[owner][spender] = current - value;
        }
    }
}
