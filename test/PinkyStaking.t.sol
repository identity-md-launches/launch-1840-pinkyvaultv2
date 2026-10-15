// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PinkyStaking} from "../src/PinkyStaking.sol";
import {MockERC20} from "./mocks/Mocks.sol";

contract PinkyStakingTest is Test {
    MockERC20 imd;
    MockERC20 pinky;
    PinkyStaking staking;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_790_000_000);
        imd = new MockERC20("Identity.md", "IMD");
        pinky = new MockERC20("Pinky", "PINKY");
        staking = new PinkyStaking(address(pinky), address(imd));
        pinky.mint(alice, 100 ether);
        pinky.mint(bob, 100 ether);
        vm.prank(alice);
        pinky.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        pinky.approve(address(staking), type(uint256).max);
        imd.mint(address(this), 1_000 ether);
        imd.approve(address(staking), type(uint256).max);
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        staking.stake(amount);
    }

    function _unstake(address who, uint256 amount) internal {
        vm.prank(who);
        staking.unstake(amount);
    }

    function test_ConstructorRefusesBadInput() public {
        vm.expectRevert(PinkyStaking.InvalidConfiguration.selector);
        new PinkyStaking(address(0), address(imd));
        vm.expectRevert(PinkyStaking.InvalidConfiguration.selector);
        new PinkyStaking(address(pinky), address(0));
        vm.expectRevert(PinkyStaking.InvalidConfiguration.selector);
        new PinkyStaking(address(pinky), address(pinky));
    }

    function test_NotifyNeedsStakersAndARealAmount() public {
        uint256 tooSmall = staking.MIN_REWARD() - 1;
        vm.expectRevert(PinkyStaking.RewardTooSmall.selector);
        staking.notify(tooSmall);
        vm.expectRevert(PinkyStaking.NoStakers.selector);
        staking.notify(1 ether);
    }

    function test_StreamIsSharedByStakeOverTime() public {
        _stake(alice, 3 ether);
        _stake(bob, 1 ether);
        staking.notify(4 ether);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertApproxEqAbs(staking.earned(alice), 3 ether, 1e7);
        assertApproxEqAbs(staking.earned(bob), 1 ether, 1e7);

        vm.prank(alice);
        staking.claim();
        assertApproxEqAbs(imd.balanceOf(alice), 3 ether, 1e7);
        vm.prank(alice);
        vm.expectRevert(PinkyStaking.ZeroAmount.selector);
        staking.claim();

        _unstake(bob, 1 ether);
        assertEq(pinky.balanceOf(bob), 100 ether);
        vm.prank(bob);
        staking.claim();
        assertApproxEqAbs(imd.balanceOf(bob), 1 ether, 1e7);
    }

    /// @dev Audit finding: the stream used to skip every second nobody was staked, and the IMD for
    /// those seconds stayed in the contract forever. Now it waits for the next staker.
    function test_StreamSurvivesAPeriodWithNobodyStaked() public {
        _stake(alice, 1 ether);
        staking.notify(1 ether);
        _unstake(alice, 1 ether);
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.earned(alice), 0);

        vm.warp(vm.getBlockTimestamp() + 7 days);
        _stake(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 7 days);

        assertApproxEqAbs(staking.earned(alice), 1 ether, 1e6, "the idle stream goes to the next staker");
        vm.prank(alice);
        staking.claim();
        assertApproxEqAbs(imd.balanceOf(alice), 1 ether, 1e6);
        assertLt(imd.balanceOf(address(staking)), 1e6, "only truncation dust stays behind");
    }

    /// @dev Changed with the review fix: the stream pauses while nobody is staked, so the staker
    /// who comes back is paid what was left over the time that was left, not all at once.
    function test_AGapInTheMiddleOfTheStreamIsNotLostEither() public {
        _stake(alice, 1 ether);
        staking.notify(7 ether);
        uint256 finish = staking.periodFinish();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _unstake(alice, 1 ether);
        assertApproxEqAbs(staking.earned(alice), 1 ether, 1e7);

        vm.warp(vm.getBlockTimestamp() + 2 days);
        _stake(bob, 1 ether);
        assertEq(staking.periodFinish(), finish + 2 days, "the pause moves the end of the stream back");
        vm.warp(vm.getBlockTimestamp() + 4 days);
        assertApproxEqAbs(staking.earned(bob), 4 ether, 1e7, "the stream resumes at its rate");
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertApproxEqAbs(staking.earned(bob), 6 ether, 1e7, "and the six days that were left are paid");
        assertApproxEqAbs(staking.earned(alice) + staking.earned(bob), 7 ether, 1e7);
    }

    /// @dev Review finding: a 1 wei stake used to collect every idle second's reward at once.
    function test_AFlashStakeDuringAPauseEarnsNothing() public {
        _stake(alice, 1 ether);
        staking.notify(7 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _unstake(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 6 days);

        address flash = makeAddr("flash");
        pinky.mint(flash, 1);
        vm.startPrank(flash);
        pinky.approve(address(staking), 1);
        staking.stake(1);
        assertEq(staking.earned(flash), 0);
        vm.expectRevert(PinkyStaking.ZeroAmount.selector);
        staking.claim();
        staking.unstake(1);
        vm.stopPrank();
        assertEq(imd.balanceOf(flash), 0, "a flash stake collects nothing");

        vm.warp(vm.getBlockTimestamp() + 1);
        _stake(bob, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 6 days);
        assertApproxEqAbs(staking.earned(bob), 6 ether, 1e7, "the staker who stays is paid the rest");
    }

    function test_AStreamThatEndedWhilePausedResumesInFull() public {
        _stake(alice, 1 ether);
        staking.notify(7 ether);
        _unstake(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _stake(bob, 1 ether);
        assertEq(staking.periodFinish(), vm.getBlockTimestamp() + 7 days);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertApproxEqAbs(staking.earned(bob), 3 ether, 1e7);
        _unstake(bob, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        _stake(bob, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 4 days);
        assertApproxEqAbs(staking.earned(bob), 7 ether, 1e7);
        assertEq(staking.periodFinish(), staking.lastUpdate() + 4 days);
    }

    /// @dev Review finding: a dust `notify` every day used to restretch what was left over a fresh
    /// seven days, cutting what stakers received in the advertised week by about a third.
    function test_ADustNotifyDoesNotSlowTheStream() public {
        _stake(alice, 100 ether);
        staking.notify(22 ether);
        uint256 rate = staking.rewardRate();
        address griefer = makeAddr("griefer");
        imd.mint(griefer, 1 ether);
        vm.prank(griefer);
        imd.approve(address(staking), type(uint256).max);
        for (uint256 day; day < 7; ++day) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            vm.prank(griefer);
            staking.notify(staking.MIN_REWARD());
            assertGe(staking.rewardRate(), rate, "the rate never drops");
            assertLt(staking.rewardRate() - rate, rate / 1_000, "nor does a dust notify raise it by more than rounding");
        }
        assertGe(staking.earned(alice) + 1e9, 22 ether, "the week's stream is paid in the week");
        assertLe(staking.earned(alice), 22.07 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertApproxEqAbs(staking.earned(alice), 22.07 ether, 1e9, "the dust is paid right after");
    }

    function test_ALargerNotifyStillRaisesTheRateOverSevenDays() public {
        _stake(alice, 1 ether);
        staking.notify(7 ether);
        vm.warp(vm.getBlockTimestamp() + 4 days);
        staking.notify(11 ether);
        assertEq(staking.periodFinish(), vm.getBlockTimestamp() + 7 days);
        assertApproxEqAbs(staking.rewardRate(), uint256(14 ether) / 7 days, 1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertApproxEqAbs(staking.earned(alice), 18 ether, 1e7);
    }

    function test_ANotifyAfterAGapStillAccountsForEverything() public {
        _stake(alice, 1 ether);
        staking.notify(7 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _unstake(alice, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _stake(bob, 1 ether);
        staking.notify(7 ether);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertApproxEqAbs(staking.earned(alice) + staking.earned(bob), 14 ether, 1e7);
        vm.prank(alice);
        staking.claim();
        vm.prank(bob);
        staking.claim();
        assertLt(imd.balanceOf(address(staking)), 1e7, "nothing but dust is left after both claim");
    }

    function testFuzz_NothingIsStrandedWhenTheStreamEnds(uint256 reward, uint256 gap, uint256 a, uint256 b) public {
        reward = bound(reward, staking.MIN_REWARD(), 1_000 ether);
        gap = bound(gap, 0, 14 days);
        a = bound(a, 1, 100 ether);
        b = bound(b, 1, 100 ether);
        _stake(alice, a);
        staking.notify(reward);
        _unstake(alice, a);
        vm.warp(vm.getBlockTimestamp() + gap);
        _stake(bob, b);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 total = staking.earned(alice) + staking.earned(bob);
        assertLe(total, reward);
        assertGe(total + 1e7, reward, "only truncation dust stays behind");
    }
}
