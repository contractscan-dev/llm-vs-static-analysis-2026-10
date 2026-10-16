// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ETHVault
 * @notice Users deposit ETH, can withdraw anytime. Owner takes 1% fee on withdrawals.
 *         Self-contained: no imports, no external dependencies.
 */
contract ETHVault {
    // --- Constants ---
    uint256 public constant FEE_BPS = 100;        // 1% = 100 basis points
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // --- State ---
    address public owner;

    mapping(address => uint256) public balances;
    uint256 public totalDeposits;   // sum of user balances (excludes accrued fees)
    uint256 public accruedFees;     // fees collected, claimable by owner

    // --- Events ---
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 fee);
    event FeesCollected(address indexed owner, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // --- Modifiers ---
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // --- Constructor ---
    constructor() {
        owner = msg.sender;
    }

    // --- User functions ---

    /// @notice Deposit ETH into the vault.
    function deposit() external payable {
        require(msg.value > 0, "zero deposit");
        balances[msg.sender] += msg.value;
        totalDeposits += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Withdraw the full balance. A 1% fee goes to the owner's accrued pool.
    function withdraw() external {
        uint256 balance = balances[msg.sender];
        require(balance > 0, "nothing to withdraw");
        _withdraw(msg.sender, balance);
    }

    /// @notice Withdraw a specific amount. A 1% fee goes to the owner's accrued pool.
    function withdraw(uint256 amount) external {
        require(amount > 0, "zero amount");
        require(balances[msg.sender] >= amount, "insufficient balance");
        _withdraw(msg.sender, amount);
    }

    function _withdraw(address user, uint256 amount) internal {
        uint256 fee = (amount * FEE_BPS) / BPS_DENOMINATOR;
        uint256 payout = amount - fee;

        balances[user] -= amount;
        totalDeposits -= amount;
        accruedFees += fee;

        (bool ok, ) = payable(user).call{value: payout}("");
        require(ok, "ETH transfer failed");

        emit Withdrawn(user, payout, fee);
    }

    // --- Owner functions ---

    /// @notice Owner collects accrued withdrawal fees.
    function collectFees() external onlyOwner {
        uint256 amount = accruedFees;
        require(amount > 0, "no fees");
        accruedFees = 0;
        (bool ok, ) = payable(owner).call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit FeesCollected(owner, amount);
    }

    /// @notice Transfer ownership of the vault.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // --- Views ---

    /// @notice Preview the fee and payout for a given withdrawal amount.
    function previewWithdrawal(uint256 amount) external pure returns (uint256 payout, uint256 fee) {
        fee = (amount * FEE_BPS) / BPS_DENOMINATOR;
        payout = amount - fee;
    }

    /// @notice Total ETH currently held by the contract (user deposits + accrued fees).
    function totalAssets() external view returns (uint256) {
        return address(this).balance;
    }

    // --- Safety ---

    /// @dev Reject plain ETH transfers; users must call deposit().
    receive() external payable {
        revert("use deposit()");
    }

    fallback() external payable {
        revert("use deposit()");
    }
}
