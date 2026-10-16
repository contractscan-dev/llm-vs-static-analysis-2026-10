// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////////
                                MINIMAL INTERFACES
//////////////////////////////////////////////////////////////////////////////*/

interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

/*//////////////////////////////////////////////////////////////////////////////
                                    NFT
//////////////////////////////////////////////////////////////////////////////*/

contract MyNFT {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error ZeroAddress();
    error NonexistentToken();
    error NotAuthorized();
    error WrongFrom();
    error ToNonReceiver();
    error AlreadyMinted();
    error SoldOut();
    error WalletLimitReached();
    error SaleNotActive();
    error WrongPrice();
    error ZeroQuantity();
    error NotAllowlisted();
    error WithdrawFailed();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /*//////////////////////////////////////////////////////////////
                            ERC721 METADATA STORAGE
    //////////////////////////////////////////////////////////////*/

    string public name;
    string public symbol;
    string private _baseURI;

    /*//////////////////////////////////////////////////////////////
                              ERC721 STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;
    mapping(uint256 => address) private _approvals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    /*//////////////////////////////////////////////////////////////
                              MINT SETTINGS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_SUPPLY = 5555;
    uint256 public constant MAX_PER_WALLET = 3;
    uint256 public constant ALLOWLIST_PRICE = 0.05 ether;
    uint256 public constant PUBLIC_PRICE = 0.08 ether;

    uint256 public totalSupply;
    uint256 private _nextTokenId = 1; // token IDs start at 1

    bytes32 public merkleRoot;
    bool public allowlistActive;
    bool public publicActive;

    /// @notice How many tokens each wallet has minted across ALL phases.
    mapping(address => uint256) public mintedPerWallet;

    address public owner;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        string memory name_,
        string memory symbol_,
        string memory baseURI_,
        bytes32 merkleRoot_
    ) {
        owner = msg.sender;
        name = name_;
        symbol = symbol_;
        _baseURI = baseURI_;
        merkleRoot = merkleRoot_;
        emit Transfer(address(0), address(0), 0); // silence unused-event warning (optional)
    }

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                 MINTING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allowlist mint. `proof` must be generated for msg.sender against `merkleRoot`.
     * @dev Leaf format (matches OpenZeppelin's StandardMerkleTree with ["address"]):
     *      leaf = keccak256(bytes.concat(keccak256(abi.encode(account))))
     *
     *      JS (ethers v6 + @openzeppelin/merkle-tree):
     *        const tree = StandardMerkleTree.of(addrs.map(a => [a]), ["address"]);
     *        const root  = tree.root;
     *        const proof = tree.getProof([userAddress]);
     */
    function allowlistMint(bytes32[] calldata proof, uint256 quantity) external payable {
        if (!allowlistActive) revert SaleNotActive();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender))));
        if (!_verifyProof(proof, merkleRoot, leaf)) revert NotAllowlisted();

        _mintQuantity(quantity, ALLOWLIST_PRICE);
    }

    /// @notice Public mint, first come first served.
    function publicMint(uint256 quantity) external payable {
        if (!publicActive) revert SaleNotActive();
        _mintQuantity(quantity, PUBLIC_PRICE);
    }

    function _mintQuantity(uint256 quantity, uint256 price) private {
        if (quantity == 0) revert ZeroQuantity();
        if (totalSupply + quantity > MAX_SUPPLY) revert SoldOut();
        if (mintedPerWallet[msg.sender] + quantity > MAX_PER_WALLET) revert WalletLimitReached();
        if (msg.value != price * quantity) revert WrongPrice();

        mintedPerWallet[msg.sender] += quantity;
        totalSupply += quantity;

        for (uint256 i = 0; i < quantity; ++i) {
            _mint(msg.sender, _nextTokenId++);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            MERKLE VERIFICATION
    //////////////////////////////////////////////////////////////*/

    function _verifyProof(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; ++i) {
            bytes32 p = proof[i];
            computed = computed <= p
                ? keccak256(abi.encodePacked(computed, p))
                : keccak256(abi.encodePacked(p, computed));
        }
        return computed == root;
    }

    /*//////////////////////////////////////////////////////////////
                              ERC721 CORE
    //////////////////////////////////////////////////////////////*/

    function balanceOf(address account) public view returns (uint256) {
        if (account == address(0)) revert ZeroAddress();
        return _balanceOf[account];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address tokenOwner = _ownerOf[tokenId];
        if (tokenOwner == address(0)) revert NonexistentToken();
        return tokenOwner;
    }

    function approve(address spender, uint256 tokenId) public {
        address tokenOwner = ownerOf(tokenId); // reverts if nonexistent
        if (msg.sender != tokenOwner && !_operatorApprovals[tokenOwner][msg.sender]) {
            revert NotAuthorized();
        }
        _approvals[tokenId] = spender;
        emit Approval(tokenOwner, spender, tokenId);
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        ownerOf(tokenId); // reverts if nonexistent
        return _approvals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) public {
        if (operator == msg.sender) revert NotAuthorized();
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address tokenOwner, address operator) public view returns (bool) {
        return _operatorApprovals[tokenOwner][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        if (to == address(0)) revert ZeroAddress();

        address tokenOwner = ownerOf(tokenId);
        if (tokenOwner != from) revert WrongFrom();

        if (
            msg.sender != tokenOwner &&
            !_operatorApprovals[tokenOwner][msg.sender] &&
            msg.sender != _approvals[tokenId]
        ) {
            revert NotAuthorized();
        }

        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, data);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC721 METADATA
    //////////////////////////////////////////////////////////////*/

    function tokenURI(uint256 tokenId) public view returns (string memory) {
        ownerOf(tokenId); // reverts if nonexistent
        return string.concat(_baseURI, _toString(tokenId));
    }

    function baseURI() external view returns (string memory) {
        return _baseURI;
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC-165
            interfaceId == 0x80ac58cd || // ERC-721
            interfaceId == 0x5b5e139f; // ERC-721 Metadata
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL ERC721 LOGIC
    //////////////////////////////////////////////////////////////*/

    function _mint(address to, uint256 tokenId) internal {
        if (to == address(0)) revert ZeroAddress();
        if (_ownerOf[tokenId] != address(0)) revert AlreadyMinted();

        _balanceOf[to] += 1;
        _ownerOf[tokenId] = to;

        emit Transfer(address(0), to, tokenId);
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        delete _approvals[tokenId];

        _balanceOf[from] -= 1;
        _balanceOf[to] += 1;
        _ownerOf[tokenId] = to;

        emit Transfer(from, to, tokenId);
    }

    function _checkOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) private {
        if (to.code.length == 0) return;

        try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (
            bytes4 retval
        ) {
            if (retval != IERC721Receiver.onERC721Received.selector) revert ToNonReceiver();
        } catch {
            revert ToNonReceiver();
        }
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setMerkleRoot(bytes32 newRoot) external onlyOwner {
        merkleRoot = newRoot;
    }

    function setAllowlistActive(bool active) external onlyOwner {
        allowlistActive = active;
    }

    function setPublicActive(bool active) external onlyOwner {
        publicActive = active;
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseURI = newBaseURI;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function withdraw() external onlyOwner {
        (bool ok, ) = payable(msg.sender).call{value: address(this).balance}("");
        if (!ok) revert WithdrawFailed();
    }
}
