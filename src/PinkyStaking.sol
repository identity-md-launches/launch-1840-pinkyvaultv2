// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Stake PINKY, earn the IMD that broken promises forfeit. No owner, no settings.
/// @dev Synthetix-style accounting. A `notify` streams what it adds, with whatever is left of the
/// current stream, over seven days, never slower than the stream already runs; a staker who
/// arrives in the block of a payout earns only for the time they stay. While nobody is staked the
/// stream is paused and resumes, for the time it had left, when the next staker arrives.
contract PinkyStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidConfiguration();
    error ZeroAmount();
    error RewardTooSmall();
    error NoStakers();

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event Notified(address indexed from, uint256 amount, uint256 periodFinish);

    uint256 public constant DURATION = 7 days;
    /// @dev Anyone may add rewards. An addition never lowers the rate, so dust cannot stretch the
    /// stream; the floor keeps dust from being worth sending at all.
    uint256 public constant MIN_REWARD = 0.01 ether;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint256 public totalStaked;
    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdate;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public rewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    constructor(address stakingToken_, address rewardToken_) {
        if (stakingToken_ == address(0) || rewardToken_ == address(0) || stakingToken_ == rewardToken_) {
            revert InvalidConfiguration();
        }
        stakingToken = IERC20(stakingToken_);
        rewardToken = IERC20(rewardToken_);
    }

    /// @dev While nobody is staked `lastUpdate` stays put: the stream is paused, and `_resume`
    /// moves its end back by the time it was paused when the next staker arrives, so nothing stays
    /// in the contract forever and nobody is paid for time they were not staked.
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        if (totalStaked != 0) lastUpdate = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            rewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + (lastTimeRewardApplicable() - lastUpdate) * rewardRate * 1e18 / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        return balanceOf[account] * (rewardPerToken() - rewardPerTokenPaid[account]) / 1e18 + rewards[account];
    }

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (totalStaked == 0) _resume();
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        totalStaked -= amount;
        balanceOf[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external nonReentrant updateReward(msg.sender) {
        uint256 amount = rewards[msg.sender];
        if (amount == 0) revert ZeroAmount();
        rewards[msg.sender] = 0;
        rewardToken.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Pulls `amount` of the reward token from the caller and streams it to stakers.
    function notify(uint256 amount) external nonReentrant updateReward(address(0)) {
        if (amount < MIN_REWARD) revert RewardTooSmall();
        if (totalStaked == 0) revert NoStakers();
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 leftover = block.timestamp < periodFinish ? (periodFinish - block.timestamp) * rewardRate : 0;
        uint256 total = amount + leftover;
        uint256 period = DURATION;
        // A small addition to a running stream keeps the stream's rate and ends sooner, instead of
        // spreading what is left over a fresh seven days at a lower rate.
        if (leftover != 0 && total / DURATION < rewardRate) period = total / rewardRate;
        rewardRate = total / period;
        lastUpdate = block.timestamp;
        periodFinish = block.timestamp + period;
        emit Notified(msg.sender, amount, periodFinish);
    }

    /// @dev Resumes a stream paused while nobody was staked: what was left of it when the last
    /// staker left is streamed from now over the same length of time.
    function _resume() private {
        uint256 remaining = periodFinish - lastUpdate;
        if (remaining == 0) return;
        lastUpdate = block.timestamp;
        periodFinish = block.timestamp + remaining;
    }
}
