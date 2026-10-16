// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MOON
 * @notice Self-contained ERC20 token.
 *         - 1,000,000,000 (1 billion) total supply, minted to the deployer.
 *         - 5% tax on buys and sells, sent straight to the marketing wallet.
 *         - Owner can exclude any wallet from tax, set market pairs, change
 *           the marketing wallet and change the tax fee.
 *
 *         A "buy"/"sell" is detected by checking whether the sender or the
 *         receiver is a registered market pair (e.g. a Uniswap V2 pair).
 *         Wallet-to-wallet transfers are NOT taxed.
 */
contract MOON {
    // ---------------------------------------------------------------------
    // ERC20 metadata
    // ---------------------------------------------------------------------
    string public constant name = "MOON";
    string public constant symbol = "MOON";
    uint8 public constant decimals = 18;

    // ---------------------------------------------------------------------
    // ERC20 state
    // ---------------------------------------------------------------------
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ---------------------------------------------------------------------
    // Ownership
    // ---------------------------------------------------------------------
    address public owner;

    // ---------------------------------------------------------------------
    // Tax configuration
    // ---------------------------------------------------------------------
    address public marketingWallet;

    /// @notice Tax taken on each buy/sell, expressed in percent (5 = 5%).
    uint256 public taxFee = 5;
    uint256 public constant TAX_DENOMINATOR = 100;
    /// @notice Safety cap so the owner can never set a predatory fee.
    uint256 public constant MAX_TAX_FEE = 25;

    /// @notice Wallets that never pay tax.
    mapping(address => bool) public isTaxExempt;
    /// @notice Registered AMM pairs (Uniswap/PancakeSwap pair contracts, etc).
    mapping(address => bool) public isMarketPair;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event MarketingWalletUpdated(address indexed newWallet);
    event TaxFeeUpdated(uint256 newFee);
    event TaxExemptUpdated(address indexed account, bool exempt);
    event MarketPairUpdated(address indexed pair, bool isPair);

    modifier onlyOwner() {
        require(msg.sender == owner, "MOON: caller is not the owner");
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address marketingWallet_) {
        require(marketingWallet_ != address(0), "MOON: marketing wallet is zero address");

        owner = msg.sender;
        marketingWallet = marketingWallet_;

        uint256 supply = 1_000_000_000 * (10 ** uint256(decimals));
        totalSupply = supply;
        balanceOf[msg.sender] = supply;

        // Owner, the token contract itself and the marketing wallet pay no tax.
        isTaxExempt[msg.sender] = true;
        isTaxExempt[address(this)] = true;
        isTaxExempt[marketingWallet_] = true;

        emit OwnershipTransferred(address(0), msg.sender);
        emit Transfer(address(0), msg.sender, supply);
    }

    // ---------------------------------------------------------------------
    // ERC20 external functions
    // ---------------------------------------------------------------------

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
            require(allowed >= amount, "MOON: insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    // ---------------------------------------------------------------------
    // Internal transfer logic (with tax)
    // ---------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "MOON: transfer from the zero address");
        require(to != address(0), "MOON: transfer to the zero address");

        uint256 fromBalance = balanceOf[from];
        require(fromBalance >= amount, "MOON: transfer amount exceeds balance");

        uint256 taxAmount = 0;
        if (taxFee > 0 && _isTaxable(from, to)) {
            taxAmount = (amount * taxFee) / TAX_DENOMINATOR;
        }

        uint256 sendAmount = amount - taxAmount;

        unchecked {
            balanceOf[from] = fromBalance - amount;
        }
        balanceOf[to] += sendAmount;

        emit Transfer(from, to, sendAmount);

        if (taxAmount > 0) {
            balanceOf[marketingWallet] += taxAmount;
            emit Transfer(from, marketingWallet, taxAmount);
        }
    }

    /// @dev A transfer is taxable only if neither side is exempt AND at least
    ///      one side is a registered market pair (i.e. it is a buy or a sell).
    function _isTaxable(address from, address to) internal view returns (bool) {
        if (isTaxExempt[from] || isTaxExempt[to]) {
            return false;
        }
        return isMarketPair[from] || isMarketPair[to];
    }

    // ---------------------------------------------------------------------
    // Owner-only configuration
    // ---------------------------------------------------------------------

    /// @notice Register/unregister an AMM pair so buys and sells are taxed.
    /// @dev Call this AFTER adding initial liquidity, otherwise the initial
    ///      liquidity add would be treated as a taxable sell.
    function setMarketPair(address pair, bool value) external onlyOwner {
        require(pair != address(0), "MOON: zero address");
        isMarketPair[pair] = value;
        emit MarketPairUpdated(pair, value);
    }

    /// @notice Exclude / include a wallet from tax.
    function setTaxExempt(address account, bool exempt) external onlyOwner {
        require(account != address(0), "MOON: zero address");
        isTaxExempt[account] = exempt;
        emit TaxExemptUpdated(account, exempt);
    }

    /// @notice Change the wallet that receives the tax.
    /// @dev The new marketing wallet is automatically tax exempt.
    function setMarketingWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "MOON: zero address");
        marketingWallet = newWallet;
        isTaxExempt[newWallet] = true;
        emit MarketingWalletUpdated(newWallet);
    }

    /// @notice Change the tax fee (in percent). Capped at MAX_TAX_FEE.
    function setTaxFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_TAX_FEE, "MOON: fee above max");
        taxFee = newFee;
        emit TaxFeeUpdated(newFee);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "MOON: zero address");
        address oldOwner = owner;
        owner = newOwner;
        isTaxExempt[newOwner] = true;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}
