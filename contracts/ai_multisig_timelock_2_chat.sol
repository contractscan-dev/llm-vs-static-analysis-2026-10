// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DAOTimelock
 * @notice A simple timelock for a DAO treasury.
 *         - Admin queues transactions.
 *         - Transactions become executable 48 hours after queuing.
 *         - Admin can cancel a pending transaction before execution.
 *         - Admin can transfer admin rights.
 */
contract DAOTimelock {
    // ------------------------------------------------------------------
    // Constants & immutables
    // ------------------------------------------------------------------

    /// @notice Delay between queueing and execution (48 hours).
    uint256 public constant DELAY = 48 hours;

    /// @notice Grace period after ETA during which a tx can still be executed.
    ///         After this, the tx is considered expired and must be re-queued.
    uint256 public constant GRACE_PERIOD = 14 days;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @notice Current admin (can be a multisig / governance executor).
    address public admin;

    /// @notice Pending admin (for two-step transfer).
    address public pendingAdmin;

    /// @notice Whether the contract has been initialized (renounce lock).
    bool public initialised;

    /// @notice Represents a queued transaction.
    struct Transaction {
        address target;    // contract / address to call
        uint256 value;     // ETH to send (in wei)
        bytes data;        // calldata
        uint256 eta;       // earliest execution timestamp
        bool executed;     // has it been executed?
        bool cancelled;    // has it been cancelled?
    }

    /// @notice id => Transaction
    mapping(bytes32 => Transaction) public transactions;

    /// @notice All queued tx ids (for off-chain convenience).
    bytes32[] public queuedTxIds;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event Queued(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 eta
    );
    event Executed(
        bytes32 indexed txId,
        address indexed target,
        uint256 value,
        bytes data
    );
    event Cancelled(bytes32 indexed txId);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferCompleted(address indexed oldAdmin, address indexed newAdmin);

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------

    modifier onlyAdmin() {
        require(msg.sender == admin, "Timelock: caller is not admin");
        _;
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /**
     * @param _admin Address that will control the timelock
     *               (typically a multisig or governance executor).
     */
    constructor(address _admin) {
        require(_admin != address(0), "Timelock: admin is zero address");
        admin = _admin;
        initialised = true;
        emit AdminTransferCompleted(address(0), _admin);
    }

    // ------------------------------------------------------------------
    // Admin functions
    // ------------------------------------------------------------------

    /**
     * @notice Queue a new transaction.
     * @param target   Contract/address to call.
     * @param value    ETH value to send.
     * @param data     Calldata for the call.
     * @param salt     Random value to allow identical txs.
     * @return txId    The id of the queued transaction.
     */
    function queue(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 salt
    ) external onlyAdmin returns (bytes32 txId) {
        require(target != address(0), "Timelock: target is zero address");

        txId = keccak256(
            abi.encode(target, value, data, block.timestamp, salt)
        );

        require(
            transactions[txId].eta == 0,
            "Timelock: tx already queued"
        );

        uint256 eta = block.timestamp + DELAY;

        transactions[txId] = Transaction({
            target: target,
            value: value,
            data: data,
            eta: eta,
            executed: false,
            cancelled: false
        });

        queuedTxIds.push(txId);

        emit Queued(txId, target, value, data, eta);
    }

    /**
     * @notice Execute a queued transaction after the delay.
     */
    function execute(bytes32 txId) external {
        Transaction storage txn = transactions[txId];

        require(txn.eta != 0, "Timelock: tx does not exist");
        require(!txn.cancelled, "Timelock: tx was cancelled");
        require(!txn.executed, "Timelock: tx already executed");
        require(
            block.timestamp >= txn.eta,
            "Timelock: tx not ready"
        );
        require(
            block.timestamp <= txn.eta + GRACE_PERIOD,
            "Timelock: tx expired"
        );

        txn.executed = true;

        (bool success, bytes memory returnData) = txn.target.call{
            value: txn.value
        }(txn.data);

        if (!success) {
            // Bubble up revert reason if any.
            if (returnData.length > 0) {
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
            revert("Timelock: execution failed");
        }

        emit Executed(txId, txn.target, txn.value, txn.data);
    }

    /**
     * @notice Cancel a pending transaction.
     */
    function cancel(bytes32 txId) external onlyAdmin {
        Transaction storage txn = transactions[txId];

        require(txn.eta != 0, "Timelock: tx does not exist");
        require(!txn.executed, "Timelock: tx already executed");
        require(!txn.cancelled, "Timelock: tx already cancelled");

        txn.cancelled = true;

        emit Cancelled(txId);
    }

    // ------------------------------------------------------------------
    // Admin transfer (two-step)
    // ------------------------------------------------------------------

    function startAdminTransfer(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Timelock: new admin is zero address");
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    function acceptAdminTransfer() external {
        require(
            msg.sender == pendingAdmin,
            "Timelock: caller is not pending admin"
        );
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferCompleted(oldAdmin, admin);
    }

    function cancelAdminTransfer() external onlyAdmin {
        pendingAdmin = address(0);
        emit AdminTransferStarted(admin, address(0));
    }

    // ------------------------------------------------------------------
    // Admin escape hatch: recover ETH accidentally sent here
    // ------------------------------------------------------------------

    /**
     * @notice Recover ETH held by this contract. Only callable by admin.
     *         Useful if someone accidentally sends ETH to the timelock.
     */
    function recoverETH(address payable to, uint256 amount) external onlyAdmin {
        require(to != address(0), "Timelock: recipient is zero address");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "Timelock: ETH recovery failed");
    }

    // ------------------------------------------------------------------
    // View helpers
    // ------------------------------------------------------------------

    function getTransaction(bytes32 txId)
        external
        view
        returns (
            address target,
            uint256 value,
            bytes memory data,
            uint256 eta,
            bool executed,
            bool cancelled
        )
    {
        Transaction storage txn = transactions[txId];
        return (
            txn.target,
            txn.value,
            txn.data,
            txn.eta,
            txn.executed,
            txn.cancelled
        );
    }

    function queuedTxCount() external view returns (uint256) {
        return queuedTxIds.length;
    }

    /**
     * @notice Preview a tx id for a given set of parameters.
     *         Useful for off-chain tooling. Note: `block.timestamp` in the
     *         encoding makes the id unique per second — pass the intended
     *         queue timestamp (as used by the contract) to reproduce the id.
     */
    function computeTxId(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 timestamp,
        bytes32 salt
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data, timestamp, salt));
    }

    // ------------------------------------------------------------------
    // Receive
    // ------------------------------------------------------------------

    receive() external payable {
        // Treasury can accept ETH (e.g. from protocol revenue, donations).
    }

    fallback() external payable {}
}
