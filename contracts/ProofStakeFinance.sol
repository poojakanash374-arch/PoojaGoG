// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/**
 * @title ProofStake Finance
 * @notice A simplified staking & validator-style protocol:
 *         - Stake ERC20 collateral
 *         - Register as validator candidate
 *         - Deposit rewards pool
 *         - Earn proportional rewards
 *         - Slashing by governance / admin
 *         - Cooldown + withdrawal after stake unlock period
 * @dev This is a template. Extend with governance, reentrancy guards, oracle data, safety checks.
 */

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

contract ProofStakeFinance {
    // ------------------------------------------------
    // STRUCTS & STATE
    // ------------------------------------------------
    struct Validator {
        address addr;              // validator’s address
        uint256 stakeAmount;       // total stake by validator
        bool active;               // whether validator is in set
    }

    address public owner;

    IERC20 public collateralToken; // token people stake
    IERC20 public rewardToken;     // token used for reward payouts

    uint256 public totalStaked;
    uint256 public rewardPerStakeStored;    // accumulated reward per staked token (scaled)
    uint256 public constant PRECISION = 1e18;

    mapping(address => uint256) public stakeOf;
    mapping(address => uint256) public rewardDebt;

    mapping(address => Validator) public validators;
    address[] public validatorList;

    uint256 public unstakeCooldownBlocks = 1000; // example cooldown
    mapping(address => uint256) public unstakeRequestBlock;
    mapping(address => uint256) public unstakeRequestedAmount;

    // ------------------------------------------------
    // EVENTS
    // ------------------------------------------------
    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 requestBlock);
    event Unstaked(address indexed user, uint256 amount);
    event RewardPoolFunded(address indexed funder, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event ValidatorRegistered(address indexed validator);
    event ValidatorDeregistered(address indexed validator);
    event ValidatorSlashed(address indexed validator, uint256 amount);

    // ------------------------------------------------
    // MODIFIERS
    // ------------------------------------------------
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ------------------------------------------------
    // CONSTRUCTOR
    // ------------------------------------------------
    constructor(address _collateralToken, address _rewardToken) {
        owner = msg.sender;
        collateralToken = IERC20(_collateralToken);
        rewardToken = IERC20(_rewardToken);
    }

    // ------------------------------------------------
    // STAKING & REWARD LOGIC
    // ------------------------------------------------
    function stake(uint256 amount) external {
        require(amount > 0, "Zero stake");
        _updateRewards();

        collateralToken.transferFrom(msg.sender, address(this), amount);
        stakeOf[msg.sender] += amount;
        totalStaked += amount;

        // update reward debt
        rewardDebt[msg.sender] = (stakeOf[msg.sender] * rewardPerStakeStored) / PRECISION;

        emit Staked(msg.sender, amount);
    }

    function requestUnstake(uint256 amount) external {
        require(stakeOf[msg.sender] >= amount, "Too much unstake");

        unstakeRequestBlock[msg.sender] = block.number;
        unstakeRequestedAmount[msg.sender] = amount;

        emit UnstakeRequested(msg.sender, amount, block.number);
    }

    function withdrawUnstaked() external {
        uint256 reqBlock = unstakeRequestBlock[msg.sender];
        uint256 amount = unstakeRequestedAmount[msg.sender];
        require(amount > 0, "No pending unstake");
        require(block.number >= reqBlock + unstakeCooldownBlocks, "Cooldown not passed");

        _updateRewards();
        _claimReward(msg.sender);

        stakeOf[msg.sender] -= amount;
        totalStaked -= amount;

        unstakeRequestedAmount[msg.sender] = 0;
        unstakeRequestBlock[msg.sender] = 0;

        collateralToken.transfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    function fundRewardPool(uint256 amount) external {
        require(amount > 0, "Zero fund");
        rewardToken.transferFrom(msg.sender, address(this), amount);
        // No bookkeeping — rewards are pulled via rewardPerStakeStored
        // Just emit event
        emit RewardPoolFunded(msg.sender, amount);
    }

    function claimReward() external {
        _updateRewards();
        _claimReward(msg.sender);
    }

    function _claimReward(address user) internal {
        uint256 acc = (stakeOf[user] * rewardPerStakeStored) / PRECISION;
        uint256 debt = rewardDebt[user];
        if (acc <= debt) return;

        uint256 payout = acc - debt;
        rewardDebt[user] = acc;
        rewardToken.transfer(user, payout);

        emit RewardClaimed(user, payout);
    }

    function _updateRewards() internal {
        uint256 bal = rewardToken.balanceOf(address(this));
        if (totalStaked == 0 || bal == 0) return;
        // For simplicity: distribute all rewardToken balance as reward
        // over all stakes. In production, you'd have more controlled emission logic.
        rewardPerStakeStored += (bal * PRECISION) / totalStaked;
    }

    // ------------------------------------------------
    // VALIDATOR REGISTRY & SLASHING
    // ------------------------------------------------
    function registerValidator(address validatorAddr) external onlyOwner {
        require(!validators[validatorAddr].active, "Already validator");
        validators[validatorAddr] = Validator({
            addr: validatorAddr,
            stakeAmount: stakeOf[validatorAddr],
            active: true
        });
        validatorList.push(validatorAddr);

        emit ValidatorRegistered(validatorAddr);
    }

    function deregisterValidator(address validatorAddr) external onlyOwner {
        require(validators[validatorAddr].active, "Not validator");
        validators[validatorAddr].active = false;
        // Note: does not auto-withdraw stake — stake remains for user
        emit ValidatorDeregistered(validatorAddr);
    }

    /// @notice Slash a misbehaving validator (remove part or full stake)
    function slashValidator(address validatorAddr, uint256 slashAmount) external onlyOwner {
        Validator storage v = validators[validatorAddr];
        require(v.active, "Not a validator");
        uint256 userStake = stakeOf[validatorAddr];
        require(userStake >= slashAmount, "Slash too big");

        // Update global rewards before changing stake
        _updateRewards();
        _claimReward(validatorAddr);

        stakeOf[validatorAddr] -= slashAmount;
        totalStaked -= slashAmount;
        v.stakeAmount = stakeOf[validatorAddr];

        // Send slashed collateral to owner / treasury
        collateralToken.transfer(owner, slashAmount);

        emit ValidatorSlashed(validatorAddr, slashAmount);
    }

    // ------------------------------------------------
    // VIEWERS
    // ------------------------------------------------
    function pendingReward(address user) external view returns (uint256) {
        uint256 stored = rewardPerStakeStored;
        uint256 bal = rewardToken.balanceOf(address(this));
        if (totalStaked > 0 && bal > 0) {
            stored += (bal * PRECISION) / totalStaked;
        }
        uint256 acc = (stakeOf[user] * stored) / PRECISION;
        uint256 debt = rewardDebt[user];
        return (acc > debt ? acc - debt : 0);
    }

    function getValidatorList() external view returns (address[] memory) {
        return validatorList;
    }

    // ------------------------------------------------
    // ADMIN
    // ------------------------------------------------
    function updateUnstakeCooldown(uint256 blocks) external onlyOwner {
        unstakeCooldownBlocks = blocks;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}
