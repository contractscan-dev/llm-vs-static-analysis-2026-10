// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title FeeToken
 * @notice ERC-20 with 2% treasury fee, 2% burn fee, and owner-controlled max wallet limit.
 */
contract FeeToken {
    // --- ERC-20 metadata ---
    string public name = "FeeToken";
    string public symbol = "FEE";
    uint8 public constant decimals = 18;

    // --- ERC-20 state ---
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // --- Fee configuration ---
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public treasuryFeeBps = 200; // 2.00%
    uint256 public burnFeeBps = 200;     // 2.00%

    // --- Addresses ---
    address public owner;
    address public treasury;

    // --- Max wallet limit (2% of supply) ---
    uint256 public maxWallet;       // absolute token amount
    bool public maxWalletEnabled = true;

    // --- Events ---
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event FeesUpdated(uint256 treasuryFeeBps, uint256 burnFeeBps);
    event MaxWalletUpdated(uint256 maxWallet, bool enabled);

    // --- Errors ---
    error NotOwner();
    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();
    error MaxWalletExceeded();
    error FeesTooHigh();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /**
     * @param initialSupply Total supply minted to deployer (in whole tokens, scaled by 1e18).
     * @param treasuryAddress Address that receives the treasury fee.
     */
    constructor(uint256 initialSupply, address treasuryAddress) {
        if (treasuryAddress == address(0)) revert ZeroAddress();
        owner = msg.sender;
        treasury = treasuryAddress;

        uint256 supply = initialSupply * 10 ** uint256(decimals);
        totalSupply = supply;
        balanceOf[msg.sender] = supply;

        // 2% of supply as max wallet
        maxWallet = (supply * 200) / FEE_DENOMINATOR;

        emit Transfer(address(0), msg.sender, supply);
        emit OwnershipTransferred(address(0), msg.sender);
        emit TreasuryUpdated(address(0), treasuryAddress);
        emit MaxWalletUpdated(maxWallet, true);
    }

    // ---------------------------
    // Core ERC-20
    // ---------------------------

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    // ---------------------------
    // Internal transfer with fees
    // ---------------------------

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();

        uint256 treasuryFee = (amount * treasuryFeeBps) / FEE_DENOMINATOR;
        uint256 burnFee = (amount * burnFeeBps) / FEE_DENOMINATOR;
        uint256 sendAmount = amount - treasuryFee - burnFee;

        // Enforce max wallet on the recipient (skip for treasury & owner disables)
        if (maxWalletEnabled) {
            uint256 newBalance = balanceOf[to] + sendAmount;
            if (to != treasury && to != owner) {
                if (newBalance > maxWallet) revert MaxWalletExceeded();
            }
        }

        // Debit sender
        unchecked {
            balanceOf[from] -= amount;
        }

        // Credit recipient
        if (sendAmount > 0) {
            balanceOf[to] += sendAmount;
            emit Transfer(from, to, sendAmount);
        }

        // Treasury fee
        if (treasuryFee > 0) {
            balanceOf[treasury] += treasuryFee;
            emit Transfer(from, treasury, treasuryFee);
        }

        // Burn
        if (burnFee > 0) {
            totalSupply -= burnFee;
            emit Transfer(from, address(0), burnFee);
        }
    }

    // ---------------------------
    // Owner functions
    // ---------------------------

    /// @notice Permanently disables the max wallet limit.
    function disableMaxWallet() external onlyOwner {
        maxWalletEnabled = false;
        emit MaxWalletUpdated(maxWallet, false);
    }

    /// @notice Re-enables the max wallet limit (if it was disabled).
    function enableMaxWallet() external onlyOwner {
        maxWalletEnabled = true;
        emit MaxWalletUpdated(maxWallet, true);
    }

    /// @notice Updates the max wallet absolute amount.
    function setMaxWallet(uint256 newMaxWallet) external onlyOwner {
        maxWallet = newMaxWallet;
        emit MaxWalletUpdated(newMaxWallet, maxWalletEnabled);
    }

    /// @notice Updates the treasury address.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /**
     * @notice Updates fee percentages in basis points.
     * @dev Combined fees cannot exceed 20% (2000 bps).
     */
    function setFees(uint256 newTreasuryFeeBps, uint256 newBurnFeeBps) external onlyOwner {
        if (newTreasuryFeeBps + newBurnFeeBps > 2000) revert FeesTooHigh();
        treasuryFeeBps = newTreasuryFeeBps;
        burnFeeBps = newBurnFeeBps;
        emit FeesUpdated(newTreasuryFeeBps, newBurnFeeBps);
    }

    /// @notice Transfers ownership of the contract.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
