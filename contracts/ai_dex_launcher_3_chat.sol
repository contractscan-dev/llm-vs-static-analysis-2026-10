// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TokenSwap
 * @notice Users swap your ERC20 token for ETH. Owner sets the price (tokens per wei),
 *         collects a 2% fee in tokens, and can change the fee recipient.
 */
contract TokenSwap {
    // ---------------------------------------------------------------------
    // Minimal ERC20 interface (so we don't need imports)
    // ---------------------------------------------------------------------
    interface IERC20 {
        function transferFrom(address from, address to, uint256 amount) external returns (bool);
        function transfer(address to, uint256 amount) external returns (bool);
        function balanceOf(address account) external view returns (uint256);
    }

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------
    IERC20 public immutable token;       // the token users pay with
    address public owner;                // contract owner
    address public feeRecipient;         // receives the 2% fee (in tokens)

    // Price: number of tokens (in token base units) required per 1 wei of ETH.
    // e.g. if you want 1 token per 1 ETH (assuming 18 decimals), set tokensPerWei = 1e18 / 1e18 = 1
    //      if you want 1000 tokens per 1 ETH, set tokensPerWei = 1000e18 / 1e18 = 1000
    uint256 public tokensPerWei;

    uint256 public constant FEE_BPS = 200; // 2% = 200 basis points
    uint256 public constant BPS_DENOMINATOR = 10_000;

    bool private locked; // simple reentrancy guard

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Swap(
        address indexed user,
        uint256 ethReceived,
        uint256 tokensPaid,
        uint256 feeTokens
    );
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event OwnershipTransferred(address oldOwner, address newOwner);
    event EthWithdrawn(address to, uint256 amount);
    event TokensWithdrawn(address to, uint256 amount);

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier nonReentrant() {
        require(!locked, "Reentrant");
        locked = true;
        _;
        locked = false;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    /**
     * @param _token         Address of the ERC20 token users will swap from.
     * @param _feeRecipient  Address that will receive the 2% token fee.
     * @param _tokensPerWei  Initial price: token base units per 1 wei of ETH.
     */
    constructor(address _token, address _feeRecipient, uint256 _tokensPerWei) {
        require(_token != address(0), "token=0");
        require(_feeRecipient != address(0), "recipient=0");
        require(_tokensPerWei > 0, "price=0");

        token = IERC20(_token);
        owner = msg.sender;
        feeRecipient = _feeRecipient;
        tokensPerWei = _tokensPerWei;
    }

    // ---------------------------------------------------------------------
    // Core swap: user sends ETH, receives ETH, pays tokens (incl. 2% fee)
    // ---------------------------------------------------------------------
    /**
     * @notice Swap tokens for ETH at the owner-set price.
     * @dev The caller must have approved this contract for `tokensPerWei * msg.value` tokens.
     *      Sends ETH to the caller and the 2% fee in tokens to feeRecipient.
     */
    function swap() external payable nonReentrant {
        uint256 ethAmount = msg.value;
        require(ethAmount > 0, "no ETH sent");

        // Total tokens required for this amount of ETH (gross, including fee)
        uint256 grossTokens = ethAmount * tokensPerWei;
        require(grossTokens > 0, "amount too small");

        // 2% fee is taken out of grossTokens
        uint256 feeTokens = (grossTokens * FEE_BPS) / BPS_DENOMINATOR;
        uint256 userTokens = grossTokens - feeTokens;

        // Pull tokens from the user
        require(
            token.transferFrom(msg.sender, address(this), grossTokens),
            "transferFrom failed"
        );

        // Send fee to fee recipient
        if (feeTokens > 0) {
            require(token.transfer(feeRecipient, feeTokens), "fee transfer failed");
        }

        // Send ETH to the user
        (bool ok, ) = payable(msg.sender).call{value: ethAmount}("");
        require(ok, "ETH send failed");

        // userTokens is what the user "paid" for the ETH (gross minus fee)
        emit Swap(msg.sender, ethAmount, userTokens, feeTokens);
    }

    // ---------------------------------------------------------------------
    // Owner functions
    // ---------------------------------------------------------------------
    function setPrice(uint256 _tokensPerWei) external onlyOwner {
        require(_tokensPerWei > 0, "price=0");
        emit PriceUpdated(tokensPerWei, _tokensPerWei);
        tokensPerWei = _tokensPerWei;
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "recipient=0");
        emit FeeRecipientUpdated(feeRecipient, _feeRecipient);
        feeRecipient = _feeRecipient;
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "owner=0");
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    /// @notice Withdraw any ETH that ends up in the contract (should not normally happen).
    function withdrawEth(address to, uint256 amount) external onlyOwner {
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "ETH withdraw failed");
        emit EthWithdrawn(to, amount);
    }

    /// @notice Withdraw any ERC20 tokens (should not normally happen since fees auto-forward).
    function withdrawTokens(address to, uint256 amount) external onlyOwner {
        require(token.transfer(to, amount), "token withdraw failed");
        emit TokensWithdrawn(to, amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------
    /// @notice Preview the token amounts for a given ETH amount.
    function quote(uint256 ethAmount)
        external
        view
        returns (uint256 grossTokens, uint256 feeTokens, uint256 userTokens)
    {
        grossTokens = ethAmount * tokensPerWei;
        feeTokens = (grossTokens * FEE_BPS) / BPS_DENOMINATOR;
        userTokens = grossTokens - feeTokens;
    }
}
