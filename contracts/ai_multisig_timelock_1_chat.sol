// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MultisigWallet
 * @notice 3-owner multisig requiring 2-of-3 confirmations to execute any transaction.
 *         Each transaction can carry arbitrary calldata and ETH value.
 */
contract MultisigWallet {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct Transaction {
        address to;       // destination address
        uint256 value;    // ETH amount (wei)
        bytes data;       // calldata for the call
        bool executed;    // whether the transaction has been executed
        uint256 confirmations; // number of confirmations collected
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    address[3] public owners;
    mapping(address => bool) public isOwner;
    uint256 public constant REQUIRED_CONFIRMATIONS = 2;

    Transaction[] public transactions;

    // txId => owner => confirmed?
    mapping(uint256 => mapping(address => bool)) public confirmations;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Deposit(address indexed sender, uint256 amount, uint256 balance);

    event Submission(uint256 indexed txId);
    event Confirmation(address indexed owner, uint256 indexed txId);
    event Revocation(address indexed owner, uint256 indexed txId);
    event Execution(uint256 indexed txId);

    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event RequirementChanged(uint256 required);

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyWallet() {
        require(msg.sender == address(this), "Multisig: only wallet");
        _;
    }

    modifier onlyOwner() {
        require(isOwner[msg.sender], "Multisig: not owner");
        _;
    }

    modifier txExists(uint256 _txId) {
        require(_txId < transactions.length, "Multisig: tx does not exist");
        _;
    }

    modifier notExecuted(uint256 _txId) {
        require(!transactions[_txId].executed, "Multisig: tx already executed");
        _;
    }

    modifier notConfirmed(uint256 _txId) {
        require(
            !confirmations[_txId][msg.sender],
            "Multisig: already confirmed"
        );
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /**
     * @param _owners The three owner addresses. Must be unique and non-zero.
     */
    constructor(address[3] memory _owners) {
        // Basic sanity checks
        for (uint256 i = 0; i < 3; i++) {
            address o = _owners[i];
            require(o != address(0), "Multisig: zero owner");
            require(!isOwner[o], "Multisig: duplicate owner");
            isOwner[o] = true;
            owners[i] = o;
            emit OwnerAdded(o);
        }
    }

    // ---------------------------------------------------------------------
    // Receive ETH
    // ---------------------------------------------------------------------

    receive() external payable {
        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    fallback() external payable {
        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    // ---------------------------------------------------------------------
    // Public API
    // ---------------------------------------------------------------------

    /**
     * @notice Submit a new transaction for confirmation.
     * @param _to     Destination address.
     * @param _value  ETH amount to send (wei).
     * @param _data   Calldata for the call.
     * @return txId   The ID of the newly created transaction.
     *
     * @dev The submitting owner automatically confirms the transaction.
     */
    function submitTransaction(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external onlyOwner returns (uint256 txId) {
        require(_to != address(0), "Multisig: zero destination");

        txId = transactions.length;
        transactions.push(
            Transaction({
                to: _to,
                value: _value,
                data: _data,
                executed: false,
                confirmations: 0
            })
        );
        emit Submission(txId);

        // Auto-confirm by the submitter.
        confirmTransaction(txId);
    }

    /**
     * @notice Confirm a pending transaction.
     */
    function confirmTransaction(uint256 _txId)
        public
        onlyOwner
        txExists(_txId)
        notExecuted(_txId)
        notConfirmed(_txId)
    {
        confirmations[_txId][msg.sender] = true;
        transactions[_txId].confirmations += 1;
        emit Confirmation(msg.sender, _txId);

        // Auto-execute once threshold is reached.
        if (transactions[_txId].confirmations >= REQUIRED_CONFIRMATIONS) {
            _executeTransaction(_txId);
        }
    }

    /**
     * @notice Revoke a previously given confirmation.
     */
    function revokeConfirmation(uint256 _txId)
        external
        onlyOwner
        txExists(_txId)
        notExecuted(_txId)
    {
        require(
            confirmations[_txId][msg.sender],
            "Multisig: not confirmed yet"
        );
        confirmations[_txId][msg.sender] = false;
        transactions[_txId].confirmations -= 1;
        emit Revocation(msg.sender, _txId);
    }

    /**
     * @notice Execute a transaction that already has enough confirmations.
     *         Anyone can call this once the threshold is met (e.g. if auto-execute
     *         was not triggered somehow).
     */
    function executeTransaction(uint256 _txId)
        external
        onlyOwner
        txExists(_txId)
        notExecuted(_txId)
    {
        require(
            transactions[_txId].confirmations >= REQUIRED_CONFIRMATIONS,
            "Multisig: not enough confirmations"
        );
        _executeTransaction(_txId);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _executeTransaction(uint256 _txId) internal notExecuted(_txId) {
        Transaction storage t = transactions[_txId];

        t.executed = true;

        (bool success, ) = t.to.call{value: t.value}(t.data);
        require(success, "Multisig: call failed");

        emit Execution(_txId);
    }

    // ---------------------------------------------------------------------
    // Utility views
    // ---------------------------------------------------------------------

    function getOwners() external view returns (address[3] memory) {
        return owners;
    }

    function getTransactionCount() external view returns (uint256) {
        return transactions.length;
    }

    function getTransaction(uint256 _txId)
        external
        view
        returns (
            address to,
            uint256 value,
            bytes memory data,
            bool executed,
            uint256 numConfirmations
        )
    {
        require(_txId < transactions.length, "Multisig: tx does not exist");
        Transaction storage t = transactions[_txId];
        return (t.to, t.value, t.data, t.executed, t.confirmations);
    }

    function isConfirmed(uint256 _txId, address _owner)
        external
        view
        returns (bool)
    {
        return confirmations[_txId][_owner];
    }
}
