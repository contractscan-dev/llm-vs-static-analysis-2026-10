// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ETHVault
 * @notice A simple ETH vault.
 *         - Anyone can deposit ETH at any time.
 *         - Users can withdraw their own ETH at any time.
 *         - The owner earns a 1% fee on every withdrawal.
 *
 * Fee model: 1% of the withdrawn amount is moved out of the user's balance and
 * accrued to `accruedFees`. The owner collects it later via `collectFees()`.
 */
contract ETHVault {
    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant WITHDRAW_FEE_BPS = 100; // 1.00%

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    address public owner;

    /// @notice ETH balance owned by each user (excluding accrued fees).
    mapping(address => uint256) public balances;

    /// @notice Fees owed to the owner, claimable via `collectFees()`.
    uint256 public accruedFees;

    /// @dev Reentrancy lock. 1 = unlocked, 2 = locked.
    uint256 private _locked = 1;

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 grossAmount, uint256 fee, uint256 netAmount);
    event FeesCollected(address indexed owner, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error TransferFailed();
    error Reentrancy();

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                 DEPOSITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit ETH into the vault. Your balance is credited 1:1.
    function deposit() public payable {
        if (msg.value == 0) revert ZeroAmount();
        balances[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Plain ETH transfers are treated as deposits.
    receive() external payable {
        deposit();
    }

    /// @notice ETH sent with unknown calldata is also treated as a deposit.
    fallback() external payable {
        deposit();
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw `amount` of your ETH. A 1% fee is taken by the owner.
    /// @param amount Gross amount to withdraw from your balance.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 bal = balances[msg.sender];
        if (amount > bal) revert InsufficientBalance();

        uint256 fee = (amount * WITHDRAW_FEE_BPS) / BPS_DENOMINATOR;
        uint256 net = amount - fee;

        // Effects before interactions.
        balances[msg.sender] = bal - amount;
        accruedFees += fee;

        emit Withdrawn(msg.sender, amount, fee, net);

        _sendETH(msg.sender, net);
    }

    /// @notice Withdraw your entire balance. A 1% fee is taken by the owner.
    function withdrawAll() external nonReentrant {
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert ZeroAmount();

        uint256 fee = (amount * WITHDRAW_FEE_BPS) / BPS_DENOMINATOR;
        uint256 net = amount - fee;

        balances[msg.sender] = 0;
        accruedFees += fee;

        emit Withdrawn(msg.sender, amount, fee, net);

        _sendETH(msg.sender, net);
    }

    /*//////////////////////////////////////////////////////////////
                                OWNER ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim all accrued withdrawal fees.
    function collectFees() external onlyOwner nonReentrant {
        uint256 amount = accruedFees;
        if (amount == 0) revert ZeroAmount();

        accruedFees = 0;

        emit FeesCollected(owner, amount);

        _sendETH(owner, amount);
    }

    /// @notice Transfer vault ownership.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total ETH held by the vault (user balances + uncollected fees).
    function totalBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Preview the fee and net amount for a given gross withdrawal.
    function previewWithdrawal(uint256 amount) external pure returns (uint256 fee, uint256 net) {
        fee = (amount * WITHDRAW_FEE_BPS) / BPS_DENOMINATOR;
        net = amount - fee;
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _sendETH(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
