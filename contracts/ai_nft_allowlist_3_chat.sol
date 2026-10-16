// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AllowlistNFT
 * @notice ERC721 NFT with allowlist free mint (EIP-712 signature based),
 *         paid public mint, max supply 10000, and 5% royalties.
 * @dev Self-contained, no imports. Paste directly into Remix.
 */
contract AllowlistNFT {
    // =============================================================
    //                           CONSTANTS
    // =============================================================

    string public constant NAME = "AllowlistNFT";
    string public constant SYMBOL = "ALNFT";

    uint256 public constant MAX_SUPPLY = 10_000;
    uint256 public constant PUBLIC_MINT_PRICE = 0.05 ether;
    uint256 public constant ROYALTY_BPS = 500; // 5.00%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // EIP-712 typehash for the allowlist ticket
    bytes32 public constant TICKET_TYPEHASH =
        keccak256("MintTicket(address minter,uint256 nonce,uint256 deadline)");

    // ERC-2981 interface id
    bytes4 private constant _INTERFACE_ID_ERC2981 = 0x2a55205a;

    // =============================================================
    //                            STORAGE
    // =============================================================

    address public owner;
    address public signer;
    address public royaltyReceiver;

    uint256 public totalSupply;
    string public baseURI;

    // ERC721 state
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // Mappings for randomness-like on-chain token URI (or sequential)
    mapping(uint256 => string) private _tokenURIs;

    // Allowlist nonce tracking
    mapping(address => uint256) public allowlistNonce;

    // Public mint flag
    bool public publicMintOpen;

    // =============================================================
    //                            EVENTS
    // =============================================================

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed spender, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event RoyaltyReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event PublicMintToggled(bool open);
    event BaseURIUpdated(string newBaseURI);

    // =============================================================
    //                          MODIFIERS
    // =============================================================

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "Reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    bool private _locked;

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    /**
     * @param initialSigner Backend signer address that signs allowlist tickets.
     * @param initialRoyaltyReceiver Address that receives royalties.
     * @param initialBaseURI Base URI for token metadata (e.g. "ipfs://CID/").
     */
    constructor(address initialSigner, address initialRoyaltyReceiver, string memory initialBaseURI) {
        require(initialSigner != address(0), "Signer=0");
        require(initialRoyaltyReceiver != address(0), "Receiver=0");

        owner = msg.sender;
        signer = initialSigner;
        royaltyReceiver = initialRoyaltyReceiver;
        baseURI = initialBaseURI;

        emit OwnershipTransferred(address(0), msg.sender);
        emit SignerUpdated(address(0), initialSigner);
        emit RoyaltyReceiverUpdated(address(0), initialRoyaltyReceiver);
        emit BaseURIUpdated(initialBaseURI);
    }

    // =============================================================
    //                          MINTING
    // =============================================================

    /**
     * @notice Free mint for allowlisted addresses. Requires a signature from the backend signer.
     * @param deadline Unix timestamp after which the ticket expires.
     * @param signature EIP-712 signature over MintTicket(minter, nonce, deadline).
     */
    function allowlistMint(uint256 deadline, bytes calldata signature) external nonReentrant {
        require(block.timestamp <= deadline, "Ticket expired");
        require(totalSupply < MAX_SUPPLY, "Sold out");

        uint256 nonce = allowlistNonce[msg.sender];

        bytes32 structHash = keccak256(abi.encode(TICKET_TYPEHASH, msg.sender, nonce, deadline));
        bytes32 digest = _hashTypedDataV4(structHash);

        require(_recover(digest, signature) == signer, "Bad signature");

        // Consume nonce (prevents replay)
        allowlistNonce[msg.sender] = nonce + 1;

        _mintOne(msg.sender);
    }

    /**
     * @notice Public paid mint. Opens when publicMintOpen == true.
     * @param quantity Number of tokens to mint.
     */
    function publicMint(uint256 quantity) external payable nonReentrant {
        require(publicMintOpen, "Public mint closed");
        require(quantity > 0 && quantity <= 10, "Bad quantity");
        require(totalSupply + quantity <= MAX_SUPPLY, "Sold out");
        require(msg.value == PUBLIC_MINT_PRICE * quantity, "Wrong ETH");

        for (uint256 i = 0; i < quantity; i++) {
            _mintOne(msg.sender);
        }
    }

    function _mintOne(address to) private {
        uint256 tokenId = totalSupply;
        require(tokenId < MAX_SUPPLY, "Sold out");

        totalSupply = tokenId + 1;
        _owners[tokenId] = to;
        _balances[to] += 1;

        emit Transfer(address(0), to, tokenId);
    }

    // =============================================================
    //                       ERC721 STANDARD
    // =============================================================

    function balanceOf(address account) public view returns (uint256) {
        require(account != address(0), "Zero address");
        return _balances[account];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address tokenOwner = _owners[tokenId];
        require(tokenOwner != address(0), "Nonexistent token");
        return tokenOwner;
    }

    function approve(address to, uint256 tokenId) public {
        address tokenOwner = ownerOf(tokenId);
        require(msg.sender == tokenOwner || isApprovedForAll(tokenOwner, msg.sender), "Not authorized");
        _tokenApprovals[tokenId] = to;
        emit Approval(tokenOwner, to, tokenId);
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        require(_owners[tokenId] != address(0), "Nonexistent token");
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) public {
        require(operator != msg.sender, "Self approval");
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address tokenOwner, address operator) public view returns (bool) {
        return _operatorApprovals[tokenOwner][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not authorized");
        require(ownerOf(tokenId) == from, "Wrong from");
        require(to != address(0), "Transfer to zero");

        delete _tokenApprovals[tokenId];
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;

        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        if (to.code.length > 0) {
            // ERC721Receiver.onERC721Received(address,address,uint256,bytes)
            (bool ok, bytes memory ret) = to.call(
                abi.encodeWithSelector(0x150b7a02, msg.sender, from, tokenId, data)
            );
            require(
                ok && ret.length >= 32 && abi.decode(ret, (bytes4)) == 0x150b7a02,
                "Unsafe recipient"
            );
        }
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) private view returns (bool) {
        address tokenOwner = ownerOf(tokenId);
        return (spender == tokenOwner ||
            isApprovedForAll(tokenOwner, spender) ||
            getApproved(tokenId) == spender);
    }

    // =============================================================
    //                        METADATA / URI
    // =============================================================

    function tokenURI(uint256 tokenId) public view returns (string memory) {
        require(_owners[tokenId] != address(0), "Nonexistent token");
        string memory overrideURI = _tokenURIs[tokenId];
        if (bytes(overrideURI).length > 0) {
            return overrideURI;
        }
        return string(abi.encodePacked(baseURI, _toString(tokenId)));
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        baseURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    function setTokenURI(uint256 tokenId, string calldata uri) external onlyOwner {
        require(_owners[tokenId] != address(0), "Nonexistent token");
        _tokenURIs[tokenId] = uri;
    }

    // =============================================================
    //                          ROYALTIES
    // =============================================================

    /// @notice ERC-2981 royalty info.
    function royaltyInfo(uint256 /*tokenId*/, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        receiver = royaltyReceiver;
        royaltyAmount = (salePrice * ROYALTY_BPS) / BPS_DENOMINATOR;
    }

    // =============================================================
    //                        ADMIN / OWNER
    // =============================================================

    function setSigner(address newSigner) external onlyOwner {
        require(newSigner != address(0), "Signer=0");
        emit SignerUpdated(signer, newSigner);
        signer = newSigner;
    }

    function setRoyaltyReceiver(address newReceiver) external onlyOwner {
        require(newReceiver != address(0), "Receiver=0");
        emit RoyaltyReceiverUpdated(royaltyReceiver, newReceiver);
        royaltyReceiver = newReceiver;
    }

    function setPublicMintOpen(bool open) external onlyOwner {
        publicMintOpen = open;
        emit PublicMintToggled(open);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Owner=0");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function withdraw(address payable to) external onlyOwner {
        require(to != address(0), "To=0");
        (bool ok, ) = to.call{value: address(this).balance}("");
        require(ok, "Withdraw failed");
    }

    // =============================================================
    //                      EIP-712 HELPERS
    // =============================================================

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(NAME)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function _hashTypedDataV4(bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        require(signature.length == 65, "Bad sig length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        // EIP-2: reject high-s malleability
        require(
            uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0,
            "Bad s"
        );
        require(v == 27 || v == 28, "Bad v");
        address recovered = ecrecover(digest, v, r, s);
        require(recovered != address(0), "Bad sig");
        return recovered;
    }

    // =============================================================
    //                    ERC165 / INTERFACE
    // =============================================================

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC165
            interfaceId == 0x80ac58cd || // ERC721
            interfaceId == 0x5b5e139f || // ERC721Metadata
            interfaceId == _INTERFACE_ID_ERC2981; // ERC2981
    }

    // =============================================================
    //                        UTILITIES
    // =============================================================

    function _toString(uint256 value) private pure returns (string memory) {
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
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    receive() external payable {}
}
