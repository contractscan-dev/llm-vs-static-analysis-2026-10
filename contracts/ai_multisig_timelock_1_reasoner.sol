// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MultiSigWallet
/// @notice A 3-owner, 2-of-3 multisignature wallet.
///         Owners submit transactions (arbitrary `to` / `value` / `data`),
///         confirm them, and once `required` confirmations are reached any
///         owner can execute the call. The contract can also receive ETH.
contract MultiSigWallet {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed sender, uint256 amount, uint256 balance);
    event Submission(
        uint256 indexed txId,
        address indexed owner,
        address indexed to,
        uint256 value,
        bytes data
    );
    event Confirmation(uint256 indexed txId, address indexed owner);
    event Revocation(uint256 indexed txId, address indexed owner);
    event Execution(uint256 indexed txId, address indexed executor);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error InvalidOwner();
    error DuplicateOwner();
    error InvalidRequirement();
    error InvalidTarget();
    error TxDoesNotExist();
    error TxAlreadyExecuted();
    error AlreadyConfirmed();
    error NotConfirmed();
    error InsufficientConfirmations();
    error InsufficientBalance();
    error CallFailed(bytes returnData);
    error ReentrantCall();

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmations;
    }

    address[] public owners;
    mapping(address => bool) public isOwner;

    /// @dev Number of confirmations required to execute (2 for a 2-of-3 wallet).
    uint256 public immutable required;

    Transaction[] public transactions;

    /// @dev txId => owner => has confirmed
    mapping(uint256 => mapping(address => bool)) public confirmed;

    uint256 private _locked = 1;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }

    modifier txExists(uint256 txId) {
        if (txId >= transactions.length) revert TxDoesNotExist();
        _;
    }

    modifier notExecuted(uint256 txId) {
        if (transactions[txId].executed) revert TxAlreadyExecuted();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert ReentrantCall();
        _locked = 2;
        _;
        _locked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _owners   The list of owner addresses (3 for a 2-of-3 wallet).
    /// @param _required Confirmations required to execute (2 for a 2-of-3 wallet).
    constructor(address[] memory _owners, uint256 _required) {
        uint256 len = _owners.length;
        if (len == 0 || _required == 0 || _required > len) revert InvalidRequirement();

        for (uint256 i = 0; i < len; ++i) {
            address owner = _owners[i];
            if (owner == address(0)) revert InvalidOwner();
            if (isOwner[owner]) revert DuplicateOwner();

            isOwner[owner] = true;
            owners.push(owner);
        }

        required = _required;
    }

    /*//////////////////////////////////////////////////////////////
                                RECEIVE
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    /*//////////////////////////////////////////////////////////////
                              TRANSACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit a new transaction. The submitter automatically confirms it.
    /// @return txId The id of the newly created transaction.
    function submitTransaction(address to, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (uint256 txId)
    {
        if (to == address(0)) revert InvalidTarget();

        txId = transactions.length;

        transactions.push(
            Transaction({
                to: to,
                value: value,
                data: data,
                executed: false,
                confirmations: 1
            })
        );

        confirmed[txId][msg.sender] = true;

        emit Submission(txId, msg.sender, to, value, data);
        emit Confirmation(txId, msg.sender);
    }

    /// @notice Confirm a pending transaction.
    function confirmTransaction(uint256 txId)
        external
        onlyOwner
        txExists(txId)
        notExecuted(txId)
    {
        if (confirmed[txId][msg.sender]) revert AlreadyConfirmed();

        confirmed[txId][msg.sender] = true;
        transactions[txId].confirmations += 1;

        emit Confirmation(txId, msg.sender);
    }

    /// @notice Revoke a previously given confirmation.
    function revokeConfirmation(uint256 txId)
        external
        onlyOwner
        txExists(txId)
        notExecuted(txId)
    {
        if (!confirmed[txId][msg.sender]) revert NotConfirmed();

        confirmed[txId][msg.sender] = false;
        transactions[txId].confirmations -= 1;

        emit Revocation(txId, msg.sender);
    }

    /// @notice Execute a transaction once it holds enough confirmations.
    /// @dev Reverts (and therefore rolls back `executed`) if the inner call fails,
    ///      so the transaction can still be retried or revoked.
    function executeTransaction(uint256 txId)
        external
        onlyOwner
        txExists(txId)
        notExecuted(txId)
        nonReentrant
    {
        Transaction storage txn = transactions[txId];

        if (txn.confirmations < required) revert InsufficientConfirmations();
        if (address(this).balance < txn.value) revert InsufficientBalance();

        // Effects BEFORE interactions.
        txn.executed = true;

        (bool success, bytes memory returndata) = txn.to.call{value: txn.value}(txn.data);
        if (!success) revert CallFailed(returndata);

        emit Execution(txId, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function getTransactionCount() external view returns (uint256) {
        return transactions.length;
    }

    function getTransaction(uint256 txId)
        external
        view
        returns (
            address to,
            uint256 value,
            bytes memory data,
            bool executed,
            uint256 confirmations
        )
    {
        Transaction storage txn = transactions[txId];
        return (txn.to, txn.value, txn.data, txn.executed, txn.confirmations);
    }
}
