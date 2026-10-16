// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TokenLauncher
 * @notice Launch ERC20 tokens with bonding curve sales.
 *         Fee: 1% platform, 0.5% creator on every buy/sell.
 *         Bonding curve: price = basePrice + slope * supply
 * @dev Self-contained (no imports). Paste into Remix.
 */
contract TokenLauncher {
    // -------------------- Constants --------------------
    uint256 public constant PLATFORM_FEE_BPS = 100; // 1.00%
    uint256 public constant CREATOR_FEE_BPS  = 50;  // 0.50%
    uint256 public constant BPS_DENOM        = 10_000;

    uint256 public constant TOKENS_PER_LAUNCH = 1_000_000e18; // minted to curve
    uint256 public constant BASE_PRICE = 1e12;                 // 0.000001 ETH per token (starting)
    uint256 public constant SLOPE      = 1e6;                  // price increase per token sold

    // -------------------- Storage --------------------
    address public owner;
    address public feeRecipient;

    struct Token {
        address creator;
        string  name;
        string  symbol;
        uint256 totalSupply;     // total minted (fixed)
        uint256 curveSupply;     // tokens currently held by the curve
        uint256 reserveETH;      // ETH backing the curve (raised)
        bool    exists;
    }

    Token[] public tokens;

    // ERC20 storage
    mapping(uint256 => mapping(address => uint256)) public balanceOf;
    mapping(uint256 => mapping(address => mapping(address => uint256))) public allowance;

    // -------------------- Events --------------------
    event TokenCreated(
        uint256 indexed tokenId,
        address indexed creator,
        string name,
        string symbol
    );
    event Transfer(uint256 indexed tokenId, address indexed from, address indexed to, uint256 amount);
    event Approval(uint256 indexed tokenId, address indexed owner, address indexed spender, uint256 amount);
    event Bought(uint256 indexed tokenId, address indexed buyer, uint256 tokensOut, uint256 ethIn);
    event Sold(uint256 indexed tokenId, address indexed seller, uint256 tokensIn, uint256 ethOut);
    event FeePaid(uint256 indexed tokenId, address indexed recipient, uint256 amount, uint8 kind); // 0=platform,1=creator

    // -------------------- Modifiers --------------------
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address _feeRecipient) {
        owner = msg.sender;
        feeRecipient = _feeRecipient == address(0) ? msg.sender : _feeRecipient;
    }

    // ============================================================
    //                     TOKEN CREATION
    // ============================================================

    /**
     * @notice Launch a new token. Must send exactly the launch fee.
     */
    function createToken(string calldata name, string calldata symbol) external payable returns (uint256 tokenId) {
        require(msg.value >= launchFee(), "insufficient launch fee");

        tokenId = tokens.length;
        Token storage t = tokens.push();
        t.creator = msg.sender;
        t.name = name;
        t.symbol = symbol;
        t.totalSupply = TOKENS_PER_LAUNCH;
        t.curveSupply = TOKENS_PER_LAUNCH;
        t.reserveETH = 0;
        t.exists = true;

        // The curve itself holds all tokens initially. Represent curve as this contract
        balanceOf[tokenId][address(this)] = TOKENS_PER_LAUNCH;

        // Pay launch fee to feeRecipient
        (bool ok, ) = feeRecipient.call{value: msg.value}("");
        require(ok, "launch fee transfer failed");

        emit TokenCreated(tokenId, msg.sender, name, symbol);
        emit Transfer(tokenId, address(0), address(this), TOKENS_PER_LAUNCH);
    }

    /// @notice Launch fee — configured dynamically as cost to buy 1 token, min 0.0001 ETH.
    function launchFee() public pure returns (uint256) {
        // simple fixed fee; feel free to change
        return 0.001 ether;
    }

    // ============================================================
    //                     BONDING CURVE MATH
    // ============================================================

    /**
     * @dev Price (in wei per 1 token, scaled to 18 decimals) when `sold` tokens
     *      have been sold from the curve.
     *      price(sold) = BASE_PRICE + SLOPE * sold / 1e18
     *
     *      Solid: cumulative cost to buy `amount` tokens starting at `sold`:
     *        cost = BASE_PRICE*amount
     *             + SLOPE * ( sold*amount + amount^2/2 ) / 1e18
     *
     *      Where `amount` and `sold` are in token-wei (18 decimals).
     *      We compute integral over x in [sold, sold+amount] of price(x) dx.
     */
    function _curveCost(uint256 sold, uint256 amount) internal pure returns (uint256) {
        // integral = BASE_PRICE * amount
        //          + SLOPE/1e18 * ( sold*amount + amount*amount/2 )
        uint256 part1 = BASE_PRICE * amount;
        uint256 inner = sold * amount + (amount * amount) / 2;
        uint256 part2 = (SLOPE * inner) / 1e18;
        return part1 + part2;
    }

    /**
     * @dev Inverse of _curveCost: how many tokens out for a given eth amount,
     *      starting at `sold` sold.
     *      Solve:  eth = BASE_PRICE*a + SLOPE/1e18 * ( sold*a + a^2/2 )
     *      => (SLOPE/(2e18)) a^2 + (BASE_PRICE + SLOPE*sold/1e18) a - eth = 0
     *      a = (-b + sqrt(b^2 + 4*c*eth)) / (2*c)   where c = SLOPE/(2e18)
     */
    function _tokensOut(uint256 sold, uint256 ethIn) internal pure returns (uint256) {
        if (ethIn == 0) return 0;
        // c = SLOPE / (2 * 1e18)
        // b = BASE_PRICE + SLOPE * sold / 1e18
        // discriminant = b^2 + 4*c*eth
        // We work with a scaled discriminant to keep precision.

        uint256 b = BASE_PRICE + (SLOPE * sold) / 1e18;
        // c_scaled = SLOPE / 2 (so we take sqrt on scaled form)
        // Use quadratic formula with careful scaling:
        // a = ( -b + sqrt(b^2 + 2*SLOPE*eth/1e18) ) * 1e18 / SLOPE
        // Let's derive: 4*c*eth = 4 * SLOPE/(2e18) * eth = 2*SLOPE*eth/1e18
        uint256 disc = b * b + (2 * SLOPE * ethIn) / 1e18;
        uint256 sq = _sqrt(disc);
        if (sq <= b) return 0;
        uint256 num = (sq - b) * 1e18;
        return num / SLOPE;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    // ============================================================
    //                          BUY
    // ============================================================

    /**
     * @notice Buy tokens from the curve with ETH.
     * @param tokenId   The launched token to buy.
     * @param minOut    Slippage protection (min tokens received).
     */
    function buy(uint256 tokenId, uint256 minOut) external payable returns (uint256 tokensOut) {
        Token storage t = tokens[tokenId];
        require(t.exists, "no token");
        require(msg.value > 0, "no eth");
        require(t.curveSupply > 0, "curve empty (sold out)");

        uint256 sold = t.totalSupply - t.curveSupply;

        // Gross tokens based on full ETH input
        uint256 grossTokens = _tokensOut(sold, msg.value);
        require(grossTokens > 0, "amount too small");
        // Clamp to available curve supply
        if (grossTokens > t.curveSupply) {
            grossTokens = t.curveSupply;
        }

        // Cost of those tokens (curve ETH)
        uint256 curveCost = _curveCost(sold, grossTokens);
        // Fee is charged ON TOP of curve cost by taking it from msg.value
        uint256 platformFee = (curveCost * PLATFORM_FEE_BPS) / BPS_DENOM;
        uint256 creatorFee  = (curveCost * CREATOR_FEE_BPS)  / BPS_DENOM;
        uint256 totalNeed = curveCost + platformFee + creatorFee;

        // If user sent more than needed, refund (they get fewer tokens than msg.value would buy after fees)
        if (totalNeed > msg.value) {
            // Reduce tokens so that totalNeed <= msg.value
            // Solve iteratively: compute for lower token amount
            // Simple approximation: scale down tokens by ratio (msg.value / totalNeed)
            uint256 scaledTokens = (grossTokens * msg.value) / totalNeed;
            grossTokens = scaledTokens;
            curveCost = _curveCost(sold, grossTokens);
            platformFee = (curveCost * PLATFORM_FEE_BPS) / BPS_DENOM;
            creatorFee  = (curveCost * CREATOR_FEE_BPS)  / BPS_DENOM;
            totalNeed = curveCost + platformFee + creatorFee;
        }

        require(totalNeed <= msg.value, "slippage");
        require(grossTokens >= minOut, "slippage (minOut)");

        // Effects
        t.curveSupply -= grossTokens;
        t.reserveETH  += curveCost;
        balanceOf[tokenId][msg.sender] += grossTokens;

        // Pay fees
        if (platformFee > 0) {
            (bool okP, ) = feeRecipient.call{value: platformFee}("");
            require(okP, "platform fee failed");
            emit FeePaid(tokenId, feeRecipient, platformFee, 0);
        }
        if (creatorFee > 0) {
            (bool okC, ) = t.creator.call{value: creatorFee}("");
            require(okC, "creator fee failed");
            emit FeePaid(tokenId, t.creator, creatorFee, 1);
        }

        // Refund excess
        uint256 refund = msg.value - totalNeed;
        if (refund > 0) {
            (bool okR, ) = msg.sender.call{value: refund}("");
            require(okR, "refund failed");
        }

        tokensOut = grossTokens;
        emit Transfer(tokenId, address(this), msg.sender, grossTokens);
        emit Bought(tokenId, msg.sender, grossTokens, curveCost);
    }

    // ============================================================
    //                          SELL
    // ============================================================

    /**
     * @notice Sell tokens back to the curve.
     * @param tokenId   Token to sell.
     * @param amount    Amount of tokens (18-decimals) to sell.
     * @param minOut    Slippage protection (min ETH received).
     */
    function sell(uint256 tokenId, uint256 amount, uint256 minOut) external returns (uint256 ethOut) {
        Token storage t = tokens[tokenId];
        require(t.exists, "no token");
        require(amount > 0, "amount 0");
        require(balanceOf[tokenId][msg.sender] >= amount, "balance");

        // Curve price the tokens as if they reduce supply from its current point.
        // gross ETH = curveCost(sold_before - amount, amount) where sold_before = total - curveSupply
        // Which equals: expensive end. Use cumulative difference.
        uint256 soldBefore = t.totalSupply - t.curveSupply;
        // Cost of buying `amount` starting at (soldBefore - amount)
        uint256 grossETH = _curveCost(soldBefore - amount, amount);

        uint256 platformFee = (grossETH * PLATFORM_FEE_BPS) / BPS_DENOM;
        uint256 creatorFee  = (grossETH * CREATOR_FEE_BPS)  / BPS_DENOM;
        uint256 netETH = grossETH - platformFee - creatorFee;
        require(netETH >= minOut, "slippage (minOut)");
        require(t.reserveETH >= grossETH, "reserve insufficient");

        // Effects
        balanceOf[tokenId][msg.sender] -= amount;
        t.curveSupply += amount;
        t.reserveETH  -= grossETH;

        // Pay fees
        if (platformFee > 0) {
            (bool okP, ) = feeRecipient.call{value: platformFee}("");
            require(okP, "platform fee failed");
            emit FeePaid(tokenId, feeRecipient, platformFee, 0);
        }
        if (creatorFee > 0) {
            (bool okC, ) = t.creator.call{value: creatorFee}("");
            require(okC, "creator fee failed");
            emit FeePaid(tokenId, t.creator, creatorFee, 1);
        }

        // Pay seller
        (bool okS, ) = msg.sender.call{value: netETH}("");
        require(okS, "seller transfer failed");

        ethOut = netETH;
        emit Transfer(tokenId, msg.sender, address(this), amount);
        emit Sold(tokenId, msg.sender, amount, netETH);
    }

    // ============================================================
    //                     ERC20 FUNCTIONS
    // ============================================================

    function transfer(uint256 tokenId, address to, uint256 amount) external returns (bool) {
        require(to != address(0), "zero addr");
        require(balanceOf[tokenId][msg.sender] >= amount, "balance");
        balanceOf[tokenId][msg.sender] -= amount;
        balanceOf[tokenId][to] += amount;
        emit Transfer(tokenId, msg.sender, to, amount);
        return true;
    }

    function approve(uint256 tokenId, address spender, uint256 amount) external returns (bool) {
        allowance[tokenId][msg.sender][spender] = amount;
        emit Approval(tokenId, msg.sender, spender, amount);
        return true;
    }

    function transferFrom(uint256 tokenId, address from, address to, uint256 amount) external returns (bool) {
        require(to != address(0), "zero addr");
        uint256 allowed = allowance[tokenId][from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[tokenId][from][msg.sender] = allowed - amount;
        }
        require(balanceOf[tokenId][from] >= amount, "balance");
        balanceOf[tokenId][from] -= amount;
        balanceOf[tokenId][to] += amount;
        emit Transfer(tokenId, from, to, amount);
        return true;
    }

    // ============================================================
    //                       VIEW HELPERS
    // ============================================================

    function totalTokens() external view returns (uint256) {
        return tokens.length;
    }

    function getToken(uint256 tokenId) external view returns (
        address creator,
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        uint256 curveSupply,
        uint256 reserveETH,
        bool exists
    ) {
        Token storage t = tokens[tokenId];
        return (t.creator, t.name, t.symbol, t.totalSupply, t.curveSupply, t.reserveETH, t.exists);
    }

    /// @notice Current spot price (wei per 1 token) on the curve.
    function currentPrice(uint256 tokenId) external view returns (uint256) {
        Token storage t = tokens[tokenId];
        require(t.exists, "no token");
        uint256 sold = t.totalSupply - t.curveSupply;
        return BASE_PRICE + (SLOPE * sold) / 1e18;
    }

    /// @notice How many tokens you'd get for `ethIn` right now (before fees).
    function quoteBuy(uint256 tokenId, uint256 ethIn) external view returns (uint256 tokensOut, uint256 totalCost) {
        Token storage t = tokens[tokenId];
        require(t.exists, "no token");
        uint256 sold = t.totalSupply - t.curveSupply;
        tokensOut = _tokensOut(sold, ethIn);
        if (tokensOut > t.curveSupply) tokensOut = t.curveSupply;
        totalCost = _curveCost(sold, tokensOut);
    }

    /// @notice ETH out for selling `amount` tokens right now (before fees).
    function quoteSell(uint256 tokenId, uint256 amount) external view returns (uint256 grossETH) {
        Token storage t = tokens[tokenId];
        require(t.exists, "no token");
        uint256 sold = t.totalSupply - t.curveSupply;
        require(amount <= sold, "too many");
        grossETH = _curveCost(sold - amount, amount);
    }

    // ============================================================
    //                       ADMIN
    // ============================================================

    function setFeeRecipient(address _new) external onlyOwner {
        require(_new != address(0), "zero");
        feeRecipient = _new;
    }

    function transferOwnership(address _new) external onlyOwner {
        require(_new != address(0), "zero");
        owner = _new;
    }

    receive() external payable {}
}
