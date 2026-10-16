// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MultiSigWallet
 * @notice A multi-signature wallet with:
 *         - Owners can be added/removed via owner proposals
 *         - Threshold can be changed via owner proposals
 *         - Standard ETH transactions require confirmation by threshold owners
 *         - A 24h delay between proposal submission and execution
 */
contract MultiSigWallet {
    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------
    uint256 public constant EXECUTION_DELAY = 24 hours;

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public threshold;

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmations;
        uint256 createdAt;
        bool cancelled;
    }

    Transaction[] public transactions;
    mapping(uint256 => mapping(address => bool)) public confirmed;

    // Owner-management proposals (add / remove / change threshold)
    enum ProposalType { AddOwner, RemoveOwner, ChangeThreshold }

    struct OwnerProposal {
        ProposalType pType;
        address target;      // owner to add or remove
        uint256 newThreshold; // for ChangeThreshold
        bool executed;
        bool cancelled;
        uint256 confirmations;
        uint256 createdAt;
    }

    OwnerProposal[] public proposals;
    mapping(uint256 => mapping(address => bool)) public proposalConfirmed;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------
    event Deposit(address indexed sender, uint256 amount);
    event Submission(uint256 indexed txId, address indexed submitter, address indexed to, uint256 value, bytes data);
    event Confirmation(uint256 indexed txId, address indexed owner);
    event Revocation(uint256 indexed txId, address indexed owner);
    event Execution(uint256 indexed txId);
    event Cancellation(uint256 indexed txId);

    event OwnerProposalCreated(uint256 indexed proposalId, ProposalType pType, address indexed target, uint256 newThreshold);
    event OwnerProposalConfirmed(uint256 indexed proposalId, address indexed owner);
    event OwnerProposalRevoked(uint256 indexed proposalId, address indexed owner);
    event OwnerProposalExecuted(uint256 indexed proposalId);
    event OwnerProposalCancelled(uint256 indexed proposalId);

    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 newThreshold);

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------
    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not an owner");
        _;
    }

    modifier txExists(uint256 _txId) {
        require(_txId < transactions.length, "Tx does not exist");
        _;
    }

    modifier notExecuted(uint256 _txId) {
        require(!transactions[_txId].executed, "Tx already executed");
        _;
    }

    modifier notCancelled(uint256 _txId) {
        require(!transactions[_txId].cancelled, "Tx cancelled");
        _;
    }

    modifier notConfirmed(uint256 _txId) {
        require(!confirmed[_txId][msg.sender], "Already confirmed");
        _;
    }

    modifier proposalExists(uint256 _pid) {
        require(_pid < proposals.length, "Proposal does not exist");
        _;
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    constructor(address[] memory _owners, uint256 _threshold) {
        require(_owners.length > 0, "Owners required");
        require(_threshold > 0 && _threshold <= _owners.length, "Invalid threshold");

        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0), "Invalid owner");
            require(!isOwner[owner], "Duplicate owner");
            isOwner[owner] = true;
            owners.push(owner);
        }
        threshold = _threshold;
    }

    // ------------------------------------------------------------------
    // Receive ETH
    // ------------------------------------------------------------------
    receive() external payable {
        if (msg.value > 0) {
            emit Deposit(msg.sender, msg.value);
        }
    }

    // ------------------------------------------------------------------
    // Standard transaction flow
    // ------------------------------------------------------------------
    function submitTransaction(address _to, uint256 _value, bytes calldata _data)
        external
        onlyOwner
        returns (uint256)
    {
        require(_to != address(0), "Invalid recipient");

        uint256 txId = transactions.length;
        transactions.push(Transaction({
            to: _to,
            value: _value,
            data: _data,
            executed: false,
            confirmations: 0,
            createdAt: block.timestamp,
            cancelled: false
        }));

        emit Submission(txId, msg.sender, _to, _value, _data);

        // Auto-confirm by submitter
        _confirmTransaction(txId);

        return txId;
    }

    function confirmTransaction(uint256 _txId)
        external
        onlyOwner
        txExists(_txId)
        notExecuted(_txId)
        notCancelled(_txId)
        notConfirmed(_txId)
    {
        _confirmTransaction(_txId);
    }

    function _confirmTransaction(uint256 _txId) internal {
        confirmed[_txId][msg.sender] = true;
        transactions[_txId].confirmations += 1;
        emit Confirmation(_txId, msg.sender);
    }

    function revokeConfirmation(uint256 _txId)
        external
        onlyOwner
        txExists(_txId)
        notExecuted(_txId)
        notCancelled(_txId)
    {
        require(confirmed[_txId][msg.sender], "Not confirmed");
        confirmed[_txId][msg.sender] = false;
        transactions[_txId].confirmations -= 1;
        emit Revocation(_txId, msg.sender);
    }

    function executeTransaction(uint256 _txId)
        external
        onlyOwner
        txExists(_txId)
        notExecuted(_txId)
        notCancelled(_txId)
    {
        Transaction storage txn = transactions[_txId];
        require(txn.confirmations >= threshold, "Not enough confirmations");
        require(block.timestamp >= txn.createdAt + EXECUTION_DELAY, "24h delay not elapsed");

        txn.executed = true;

        (bool success, ) = txn.to.call{value: txn.value}(txn.data);
        require(success, "Transaction failed");

        emit Execution(_txId);
    }

    function cancelTransaction(uint256 _txId)
        external
        onlyOwner
        txExists(_txId)
        notExecuted(_txId)
        notCancelled(_txId)
    {
        transactions[_txId].cancelled = true;
        emit Cancellation(_txId);
    }

    // ------------------------------------------------------------------
    // Owner-management proposals
    // ------------------------------------------------------------------
    function proposeAddOwner(address _newOwner) external onlyOwner returns (uint256) {
        require(_newOwner != address(0), "Invalid owner");
        require(!isOwner[_newOwner], "Already an owner");

        uint256 pid = proposals.length;
        proposals.push(OwnerProposal({
            pType: ProposalType.AddOwner,
            target: _newOwner,
            newThreshold: 0,
            executed: false,
            cancelled: false,
            confirmations: 0,
            createdAt: block.timestamp
        }));

        emit OwnerProposalCreated(pid, ProposalType.AddOwner, _newOwner, 0);
        _confirmProposal(pid);
        return pid;
    }

    function proposeRemoveOwner(address _ownerToRemove) external onlyOwner returns (uint256) {
        require(isOwner[_ownerToRemove], "Not an owner");
        // Must keep at least threshold owners after removal
        require(owners.length - 1 >= threshold, "Would leave fewer owners than threshold");

        uint256 pid = proposals.length;
        proposals.push(OwnerProposal({
            pType: ProposalType.RemoveOwner,
            target: _ownerToRemove,
            newThreshold: 0,
            executed: false,
            cancelled: false,
            confirmations: 0,
            createdAt: block.timestamp
        }));

        emit OwnerProposalCreated(pid, ProposalType.RemoveOwner, _ownerToRemove, 0);
        _confirmProposal(pid);
        return pid;
    }

    function proposeChangeThreshold(uint256 _newThreshold) external onlyOwner returns (uint256) {
        require(_newThreshold > 0 && _newThreshold <= owners.length, "Invalid threshold");
        require(_newThreshold != threshold, "Same threshold");

        uint256 pid = proposals.length;
        proposals.push(OwnerProposal({
            pType: ProposalType.ChangeThreshold,
            target: address(0),
            newThreshold: _newThreshold,
            executed: false,
            cancelled: false,
            confirmations: 0,
            createdAt: block.timestamp
        }));

        emit OwnerProposalCreated(pid, ProposalType.ChangeThreshold, address(0), _newThreshold);
        _confirmProposal(pid);
        return pid;
    }

    function confirmProposal(uint256 _pid)
        external
        onlyOwner
        proposalExists(_pid)
    {
        OwnerProposal storage p = proposals[_pid];
        require(!p.executed && !p.cancelled, "Closed");
        require(!proposalConfirmed[_pid][msg.sender], "Already confirmed");
        _confirmProposal(_pid);
    }

    function _confirmProposal(uint256 _pid) internal {
        proposalConfirmed[_pid][msg.sender] = true;
        proposals[_pid].confirmations += 1;
        emit OwnerProposalConfirmed(_pid, msg.sender);
    }

    function revokeProposalConfirmation(uint256 _pid)
        external
        onlyOwner
        proposalExists(_pid)
    {
        OwnerProposal storage p = proposals[_pid];
        require(!p.executed && !p.cancelled, "Closed");
        require(proposalConfirmed[_pid][msg.sender], "Not confirmed");

        proposalConfirmed[_pid][msg.sender] = false;
        p.confirmations -= 1;
        emit OwnerProposalRevoked(_pid, msg.sender);
    }

    function executeProposal(uint256 _pid)
        external
        onlyOwner
        proposalExists(_pid)
    {
        OwnerProposal storage p = proposals[_pid];
        require(!p.executed && !p.cancelled, "Closed");
        require(p.confirmations >= threshold, "Not enough confirmations");
        require(block.timestamp >= p.createdAt + EXECUTION_DELAY, "24h delay not elapsed");

        p.executed = true;

        if (p.pType == ProposalType.AddOwner) {
            require(!isOwner[p.target], "Already an owner");
            isOwner[p.target] = true;
            owners.push(p.target);
            emit OwnerAdded(p.target);
        } else if (p.pType == ProposalType.RemoveOwner) {
            require(isOwner[p.target], "Not an owner");
            _removeOwner(p.target);
            emit OwnerRemoved(p.target);

            // Safety: keep threshold <= owners length
            if (threshold > owners.length) {
                threshold = owners.length;
                emit ThresholdChanged(threshold);
            }
        } else if (p.pType == ProposalType.ChangeThreshold) {
            require(p.newThreshold > 0 && p.newThreshold <= owners.length, "Invalid threshold");
            threshold = p.newThreshold;
            emit ThresholdChanged(p.newThreshold);
        }

        emit OwnerProposalExecuted(_pid);
    }

    function cancelProposal(uint256 _pid)
        external
        onlyOwner
        proposalExists(_pid)
    {
        OwnerProposal storage p = proposals[_pid];
        require(!p.executed && !p.cancelled, "Closed");
        p.cancelled = true;
        emit OwnerProposalCancelled(_pid);
    }

    function _removeOwner(address _owner) internal {
        isOwner[_owner] = false;
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == _owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------
    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function ownersCount() external view returns (uint256) {
        return owners.length;
    }

    function transactionCount() external view returns (uint256) {
        return transactions.length;
    }

    function proposalCount() external view returns (uint256) {
        return proposals.length;
    }

    function getTransaction(uint256 _txId)
        external
        view
        txExists(_txId)
        returns (
            address to,
            uint256 value,
            bytes memory data,
            bool executed,
            bool cancelled,
            uint256 confirmations,
            uint256 createdAt,
            uint256 executableAt
        )
    {
        Transaction storage t = transactions[_txId];
        return (
            t.to,
            t.value,
            t.data,
            t.executed,
            t.cancelled,
            t.confirmations,
            t.createdAt,
            t.createdAt + EXECUTION_DELAY
        );
    }

    function getProposal(uint256 _pid)
        external
        view
        proposalExists(_pid)
        returns (
            ProposalType pType,
            address target,
            uint256 newThreshold,
            bool executed,
            bool cancelled,
            uint256 confirmations,
            uint256 createdAt,
            uint256 executableAt
        )
    {
        OwnerProposal storage p = proposals[_pid];
        return (
            p.pType,
            p.target,
            p.newThreshold,
            p.executed,
            p.cancelled,
            p.confirmations,
            p.createdAt,
            p.createdAt + EXECUTION_DELAY
        );
    }
}
