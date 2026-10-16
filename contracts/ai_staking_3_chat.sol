// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SimpleStaking
 * @notice Stake ETH for 30 days, earn daily rewards, 10% penalty on early withdrawal
 * @dev Rewards must be funded by owner via fundRewards(). Reward rate is per-second.
 */
contract SimpleStaking {
    uint256 public constant LOCK_PERIOD = 30 days;
    uint256 public constant PENALTY_BPS = 1000; // 10% in basis points
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // rewardRate: wei of reward per second per wei staked (scaled by 1e18)
    // rewardPerTokenStored uses the classic accumulator pattern.
    uint256 public rewardRatePerSecond; // reward wei per second for the ENTIRE pool
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    uint256 public totalStaked;

    address public owner;

    struct Stake {
        uint256 amount;
        uint256 rewardPerTokenPaid;
        uint256 rewards;
        uint256 unlockTime;
    }

    mapping(address => Stake) public stakes;

    // Track when rewards were last funded to enforce solvency
    uint256 public rewardPoolBalance; // ETH reserved for rewards

    event Staked(address indexed user, uint256 amount, uint256 unlockTime);
    event Withdrawn(address indexed user, uint256 amount, uint256 penalty);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsFunded(address indexed funder, uint256 amount);
    event RewardRateUpdated(uint256 newRate);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            Stake storage s = stakes[account];
            s.rewards = earned(account);
            s.rewardPerTokenPaid = rewardPerTokenStored;
        }
        _;
    }

    constructor() {
        owner = msg.sender;
        lastUpdateTime = block.timestamp;
    }

    /**
     * @notice Owner funds the reward pool. The given amount is distributed
     *         linearly to stakers. Caller can call multiple times to extend.
     *         For simplicity, each fund() call sets a NEW reward rate that
     *         spreads `amount + leftover` over `duration`.
     */
    function fundRewards(uint256 duration) external payable onlyOwner updateReward(address(0)) {
        require(msg.value > 0, "no funds");
        require(duration > 0, "no duration");

        // Any remaining unfunded rewards stay; we just increase pool balance
        rewardPoolBalance += msg.value;

        // New rate = (existing pool) / duration
        rewardRatePerSecond = rewardPoolBalance / duration;

        emit RewardsFunded(msg.sender, msg.value);
        emit RewardRateUpdated(rewardRatePerSecond);
    }

    /**
     * @notice Update reward rate explicitly (owner only)
     */
    function setRewardRate(uint256 ratePerSecond) external onlyOwner updateReward(address(0)) {
        rewardRatePerSecond = ratePerSecond;
        emit RewardRateUpdated(ratePerSecond);
    }

    function stake() external payable updateReward(msg.sender) {
        require(msg.value > 0, "zero stake");
        Stake storage s = stakes[msg.sender];

        // Allow topping up; unlocks reset to 30 days from now
        s.amount += msg.value;
        s.unlockTime = block.timestamp + LOCK_PERIOD;
        totalStaked += msg.value;

        emit Staked(msg.sender, msg.value, s.unlockTime);
    }

    /**
     * @notice Withdraw staked ETH. If before unlock, 10% penalty goes to owner.
     *         Accrued rewards are paid out at the same time.
     */
    function withdraw() external updateReward(msg.sender) {
        Stake storage s = stakes[msg.sender];
        uint256 amount = s.amount;
        require(amount > 0, "nothing staked");

        uint256 penalty = 0;
        if (block.timestamp < s.unlockTime) {
            penalty = (amount * PENALTY_BPS) / BPS_DENOMINATOR;
        }

        uint256 payout = amount - penalty;
        uint256 reward = s.rewards;

        // Reset stake
        totalStaked -= amount;
        s.amount = 0;
        s.rewards = 0;
        s.unlockTime = 0;

        if (penalty > 0) {
            (bool okOwner, ) = owner.call{value: penalty}("");
            require(okOwner, "penalty transfer failed");
        }

        if (reward > 0) {
            // Cap at available reward pool
            if (reward > rewardPoolBalance) {
                reward = rewardPoolBalance;
            }
            rewardPoolBalance -= reward;
            (bool okR, ) = msg.sender.call{value: reward}("");
            require(okR, "reward transfer failed");
            emit RewardPaid(msg.sender, reward);
        }

        (bool ok, ) = msg.sender.call{value: payout}("");
        require(ok, "withdraw transfer failed");

        emit Withdrawn(msg.sender, payout, penalty);
    }

    /**
     * @notice Claim only rewards without touching principal.
     */
    function claimRewards() external updateReward(msg.sender) {
        uint256 reward = stakes[msg.sender].rewards;
        require(reward > 0, "no rewards");
        if (reward > rewardPoolBalance) {
            reward = rewardPoolBalance;
        }
        rewardPoolBalance -= reward;
        stakes[msg.sender].rewards = 0;

        (bool ok, ) = msg.sender.call{value: reward}("");
        require(ok, "reward transfer failed");
        emit RewardPaid(msg.sender, reward);
    }

    // ---- View helpers ----

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        uint256 elapsed = block.timestamp - lastUpdateTime;
        uint256 rewardAccrued = elapsed * rewardRatePerSecond;
        return rewardPerTokenStored + (rewardAccrued * 1e18) / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        Stake storage s = stakes[account];
        uint256 rpt = rewardPerToken();
        uint256 delta = rpt - s.rewardPerTokenPaid;
        return s.rewards + (s.amount * delta) / 1e18;
    }

    function timeUntilUnlock(address account) external view returns (uint256) {
        uint256 u = stakes[account].unlockTime;
        if (u <= block.timestamp) return 0;
        return u - block.timestamp;
    }
}
