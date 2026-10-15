// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PinkyStaking} from "../src/PinkyStaking.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @dev Three stakers and two notifiers, in any order, with time passing between calls. Every
/// precondition is checked first so no call reverts (`fail_on_revert` is on).
contract StakingHandler is Test {
    uint256 constant DURATION = 7 days;
    uint256 constant MAX_STAKE = 1_000 ether;

    PinkyStaking public staking;
    MockERC20 public imd;
    MockERC20 public pinky;

    address[3] public actors = [address(0xA1), address(0xA2), address(0xA3)];
    address[2] public notifiers = [address(0xF1), address(0xF2)];

    uint256 public totalNotified;
    uint256 public totalClaimed;
    uint256 public notifies;
    /// @dev Calls that ran `updateReward`, each of which may lose a little to rounding.
    uint256 public updates;
    /// @dev What the stream still held the moment the last staker left, which a pause must keep.
    uint256 public pausedOwed;
    mapping(address => uint256) public minted;
    mapping(address => uint256) public claimed;

    constructor(PinkyStaking staking_, MockERC20 imd_, MockERC20 pinky_) {
        (staking, imd, pinky) = (staking_, imd_, pinky_);
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            pinky.approve(address(staking), type(uint256).max);
        }
        for (uint256 i; i < notifiers.length; ++i) {
            vm.prank(notifiers[i]);
            imd.approve(address(staking), type(uint256).max);
        }
    }

    function stake(uint256 who, uint256 amount) external {
        address actor = actors[who % actors.length];
        uint256 room = MAX_STAKE - staking.balanceOf(actor);
        if (room == 0) return;
        amount = bound(amount, 1, room);
        pinky.mint(actor, amount);
        minted[actor] += amount;
        bool resuming = staking.totalStaked() == 0;
        uint256 remainingBefore = staking.periodFinish() - staking.lastUpdate();
        uint256 earnedBefore = staking.earned(actor);
        vm.prank(actor);
        staking.stake(amount);
        if (resuming) {
            assertEq(staking.earned(actor), earnedBefore, "a pause credits nothing to the staker who ends it");
            assertEq(staking.periodFinish() - staking.lastUpdate(), remainingBefore, "a resume keeps the time left");
            if (remainingBefore != 0) assertEq(staking.lastUpdate(), block.timestamp, "and starts it now");
        }
        updates += 1;
    }

    function unstake(uint256 who, uint256 amount) external {
        address actor = actors[who % actors.length];
        uint256 held = staking.balanceOf(actor);
        if (held == 0) return;
        amount = bound(amount, 1, held);
        vm.prank(actor);
        staking.unstake(amount);
        if (staking.totalStaked() == 0) {
            pausedOwed = staking.rewardRate() * (staking.periodFinish() - staking.lastUpdate());
        }
        updates += 1;
    }

    function claim(uint256 who) external {
        address actor = actors[who % actors.length];
        uint256 owed = staking.earned(actor);
        if (owed == 0) return;
        uint256 before = imd.balanceOf(actor);
        vm.prank(actor);
        staking.claim();
        uint256 got = imd.balanceOf(actor) - before;
        assertEq(got, owed, "claim pays exactly what was earned");
        claimed[actor] += got;
        totalClaimed += got;
        updates += 1;
    }

    function notify(uint256 who, uint256 amount) external {
        if (staking.totalStaked() == 0) return;
        address from = notifiers[who % notifiers.length];
        amount = bound(amount, staking.MIN_REWARD(), 1_000 ether);
        imd.mint(from, amount);
        uint256 rateBefore = staking.rewardRate();
        uint256 finishBefore = staking.periodFinish();
        bool running = block.timestamp < finishBefore;
        vm.prank(from);
        staking.notify(amount);
        if (running) assertGe(staking.rewardRate(), rateBefore, "a notify never lowers a running rate");
        assertGe(staking.periodFinish(), finishBefore, "a notify never moves the end earlier");
        assertLe(staking.periodFinish(), block.timestamp + DURATION, "nor past seven days");
        totalNotified += amount;
        notifies += 1;
        updates += 1;
    }

    function pass(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 10 days));
    }

    function sumStaked() external view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += staking.balanceOf(actors[i]);
        }
    }

    function sumEarned() external view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += staking.earned(actors[i]);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
contract PinkyStakingInvariantTest is Test {
    uint256 constant DURATION = 7 days;

    PinkyStaking staking;
    MockERC20 imd;
    MockERC20 pinky;
    StakingHandler handler;

    function setUp() public {
        vm.warp(1_790_000_000);
        imd = new MockERC20("Identity.md", "IMD");
        pinky = new MockERC20("Pinky", "PINKY");
        staking = new PinkyStaking(address(pinky), address(imd));
        handler = new StakingHandler(staking, imd, pinky);
        targetContract(address(handler));
    }

    /// @notice The PINKY held is exactly the sum of what stakers can take back.
    function invariant_PinkyHeldEqualsTheStakes() public view {
        assertEq(pinky.balanceOf(address(staking)), staking.totalStaked());
        assertEq(staking.totalStaked(), handler.sumStaked());
    }

    /// @notice Nobody ends up with more PINKY than they were given, in the contract or out of it.
    function invariant_NobodyWithdrawsMoreThanTheyStaked() public view {
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            assertEq(pinky.balanceOf(actor) + staking.balanceOf(actor), handler.minted(actor));
        }
    }

    /// @notice The IMD held always covers everything stakers can claim right now.
    function invariant_ImdHeldCoversWhatIsOwed() public view {
        assertGe(imd.balanceOf(address(staking)), handler.sumEarned());
    }

    /// @notice What was claimed plus what is owed never exceeds what was put in.
    function invariant_NothingIsPaidTwice() public view {
        assertLe(handler.totalClaimed() + handler.sumEarned(), handler.totalNotified());
        assertEq(imd.balanceOf(address(staking)), handler.totalNotified() - handler.totalClaimed());
    }

    /// @notice Every wei notified is claimed, owed, still streaming, idle-but-credited-next, or
    /// bounded rounding dust: nothing is stranded.
    function invariant_TheStreamAccountsForEverything() public view {
        uint256 rate = staking.rewardRate();
        uint256 applicable = staking.lastTimeRewardApplicable();
        uint256 future = rate * (staking.periodFinish() - applicable);
        uint256 idle = staking.totalStaked() == 0 ? rate * (applicable - staking.lastUpdate()) : 0;
        uint256 accounted = handler.totalClaimed() + handler.sumEarned() + future + idle;
        assertLe(accounted, handler.totalNotified(), "accounted for more than was notified");
        uint256 dust = handler.notifies() * DURATION + handler.updates() * 4_000 + 10;
        assertLe(handler.totalNotified() - accounted, dust, "IMD stranded beyond rounding");
    }

    /// @notice While nobody is staked the stream is frozen: what it held when the last staker left
    /// is exactly what it holds now, whatever was called and however much time passed.
    function invariant_APausedStreamIsFrozen() public view {
        if (staking.totalStaked() != 0) return;
        assertEq(staking.rewardRate() * (staking.periodFinish() - staking.lastUpdate()), handler.pausedOwed());
        assertEq(staking.rewardPerToken(), staking.rewardPerTokenStored(), "nothing accrues while paused");
    }

    /// @notice The clock never runs backwards, so the rate arithmetic cannot underflow.
    function invariant_ClockIsMonotonic() public view {
        assertGe(staking.periodFinish(), staking.lastUpdate());
        assertGe(staking.lastTimeRewardApplicable(), staking.lastUpdate());
    }
}
