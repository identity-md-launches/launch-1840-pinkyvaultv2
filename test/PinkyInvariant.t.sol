// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {PinkyVault} from "../src/PinkyVault.sol";
import {PinkyStaking} from "../src/PinkyStaking.sol";
import {MockERC20, MockIntake} from "./mocks/Mocks.sol";

/// @dev Drives promises through every path in any order. A call whose precondition does not hold
/// returns early, so the fuzzer spends its depth on calls that move state.
contract PinkyHandler is Test {
    uint256 constant SIGNER_PK = 0xA11CE;
    uint256 constant PRICE = 0.5 ether;

    PinkyVault public vault;
    PinkyStaking public staking;
    MockERC20 public imd;
    MockERC20 public pinky;
    MockERC20 public token;
    MockIntake public intake;
    /// @dev A second Intake the owner may switch to, so the cap on another protocol is exercised.
    MockIntake public other;

    address[3] makers = [address(0xA1), address(0xA2), address(0xA3)];
    address staker = address(0x57A4E);
    uint256 nonce;

    uint256 public deposited;
    uint256 public toIntake;
    uint256 public toMakers;
    uint256 public toAskers;
    uint256 public toStakers;
    uint256 public burned;
    uint256 public verdicts;

    /// @dev The state machine as seen after the previous call, to check every transition.
    mapping(uint256 => PinkyVault.Status) public lastStatus;
    mapping(uint256 => bool) public lastPaid;
    mapping(uint256 => uint8) public lastAttempts;
    /// @dev What each promise was made with, and the oracle fees it has paid since, at whatever
    /// price each ask found.
    mapping(uint256 => uint256) public bondAt;
    mapping(uint256 => uint256) public feesPaid;

    /// @dev Called at the end of every action: a promise only ever moves forward, one step at a
    /// time, and a settled one never reopens.
    modifier steps() {
        _;
        for (uint256 id = 1; id <= vault.count(); ++id) {
            (,,,,,,,,, uint8 attempts, PinkyVault.Status now_, bool paid,,,,) = vault.promises(id);
            PinkyVault.Status was = lastStatus[id];
            if (now_ != was) {
                if (was == PinkyVault.Status.Active) {
                    assertTrue(now_ == PinkyVault.Status.Closed, "Active only closes");
                } else if (was == PinkyVault.Status.Closed) {
                    assertTrue(
                        now_ == PinkyVault.Status.Asked || now_ == PinkyVault.Status.Refunded,
                        "Closed is asked or refunded"
                    );
                } else if (was == PinkyVault.Status.Asked) {
                    assertTrue(
                        now_ == PinkyVault.Status.Kept || now_ == PinkyVault.Status.Broken
                            || now_ == PinkyVault.Status.Refunded,
                        "Asked ends in a verdict or a refund"
                    );
                } else {
                    assertTrue(false, "a settled promise changed status");
                }
            }
            if (paid) {
                assertTrue(now_ == PinkyVault.Status.Kept || now_ == PinkyVault.Status.Broken, "paid without a verdict");
            }
            assertTrue(!lastPaid[id] || paid, "paid flag cleared");
            assertGe(attempts, lastAttempts[id], "attempts went down");
            assertLe(attempts - lastAttempts[id], 1, "attempts jumped");
            lastStatus[id] = now_;
            lastPaid[id] = paid;
            lastAttempts[id] = attempts;
        }
    }

    constructor(
        PinkyVault vault_,
        PinkyStaking staking_,
        MockERC20 imd_,
        MockERC20 pinky_,
        MockERC20 token_,
        MockIntake intake_
    ) {
        (vault, staking, imd, pinky, token, intake) = (vault_, staking_, imd_, pinky_, token_, intake_);
        other = new MockIntake(address(0xFEE), PRICE);
        pinky.mint(staker, 1_000 ether);
        vm.prank(staker);
        pinky.approve(address(staking), type(uint256).max);
    }

    function _pick(uint256 seed) internal view returns (uint256 id) {
        uint256 n = vault.count();
        return n == 0 ? 0 : bound(seed, 1, n);
    }

    function _status(uint256 id) internal view returns (PinkyVault.Status s) {
        (,,,,,,,,,, s,,,,,) = vault.promises(id);
    }

    function _current() internal view returns (MockIntake) {
        return MockIntake(address(vault.intake()));
    }

    function make(uint256 who, uint256 bond, uint256 maxOut, uint256 duration) external steps {
        address maker = makers[who % 3];
        uint256 price = _current().price();
        uint256 floor_ = 3 * price > 5 ether ? 3 * price : 5 ether;
        bond = bound(bond, floor_, 50 ether);
        duration = bound(duration, 10 minutes, 30 days);
        imd.mint(maker, bond);
        vm.startPrank(maker);
        imd.approve(address(vault), bond);
        if (price == 0) {
            vm.expectRevert(PinkyVault.InvalidPayment.selector);
            vault.make(address(token), maxOut, duration, bond);
            vm.stopPrank();
            return;
        }
        uint256 id = vault.make(address(token), maxOut, duration, bond);
        vm.stopPrank();
        deposited += bond;
        bondAt[id] = bond;
        (uint256 maxPrice,,, address madeUnder,) = vault.terms(id);
        assertEq(maxPrice, price, "the price seen at make is the cap elsewhere");
        assertEq(madeUnder, address(_current()));
    }

    /// @dev The Intake moves its price, sometimes to nothing: `make` refuses, `ask` pays it at the
    /// promise's own protocol and is capped at another.
    function setPrice(bool which, uint256 price) external steps {
        price = bound(price, 0, 5 ether);
        if (price < 0.05 ether) price = 0;
        (which ? other : intake).setPrice(price);
    }

    function switchProtocol(bool toOther) external steps {
        address owner = vault.owner();
        bytes32 action = vault.action();
        vm.prank(owner);
        vault.setProtocol(address(toOther ? other : intake), action);
    }

    function pass(uint256 secs, uint256 blocks) external steps {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 3 days));
        vm.roll(vm.getBlockNumber() + bound(blocks, 1, 100_000));
    }

    function toggleStake(uint256 amount) external steps {
        vm.startPrank(staker);
        if (staking.balanceOf(staker) == 0) staking.stake(bound(amount, 1, 1_000 ether));
        else staking.unstake(staking.balanceOf(staker));
        vm.stopPrank();
    }

    function close(uint256 seed) external steps {
        uint256 id = _pick(seed);
        if (id == 0 || _status(id) != PinkyVault.Status.Active) return;
        (,,,,,, uint64 endTime,,,,,,,,,) = vault.promises(id);
        if (vm.getBlockTimestamp() < endTime) vm.warp(endTime);
        vault.close(id);
    }

    function ask(uint256 seed) external steps {
        _ask(seed, address(0xA5CE4));
    }

    /// @dev The maker asking about their own promise: no bounty, and a watcher who re-asks takes
    /// the asker's seat.
    function askAsMaker(uint256 seed) external steps {
        uint256 id = _pick(seed);
        if (id == 0) return;
        (address maker,,,,,,,,,,,,,,,) = vault.promises(id);
        _ask(seed, maker);
    }

    function _ask(uint256 seed, address who) internal {
        uint256 id = _pick(seed);
        if (id == 0) return;
        PinkyVault.Status s = _status(id);
        (,,,,, uint64 endBlock,,, uint64 askedAt, uint8 attempts,,,,,,) = vault.promises(id);
        if (s != PinkyVault.Status.Closed && s != PinkyVault.Status.Asked) return;
        if (attempts >= vault.MAX_ATTEMPTS()) return;
        if (s == PinkyVault.Status.Asked && vm.getBlockTimestamp() < askedAt + vault.ANSWER_TIMEOUT()) return;
        if (vm.getBlockNumber() < endBlock + vault.SETTLE_DELAY_BLOCKS()) {
            vm.roll(endBlock + vault.SETTLE_DELAY_BLOCKS());
        }
        (,,,,,,,,,,,, address askerBefore,,,) = vault.promises(id);
        (address maker,,, uint256 bond,,,,,,,,,,,,) = vault.promises(id);

        // The price rules, probed rather than skipped: a zero quote, a price above what is left of
        // the bond, or a price above the one the promise was made under at another protocol, are
        // refused and move nothing.
        MockIntake cur = _current();
        uint256 price = cur.price();
        (uint256 maxPrice,,, address madeUnder,) = vault.terms(id);
        bool same = address(cur) == madeUnder;
        if (price == 0 || price > bond || (!same && price > maxPrice)) {
            uint256 held = imd.balanceOf(address(vault));
            vm.prank(who);
            vm.expectRevert(PinkyVault.InvalidPayment.selector);
            vault.ask(id);
            assertEq(imd.balanceOf(address(vault)), held);
            return;
        }
        vm.prank(who);
        vault.ask(id);
        toIntake += price;
        feesPaid[id] += price;
        (,,,,,,,,,,,, address askerAfter,,,) = vault.promises(id);
        if (askerBefore == address(0) || askerBefore == maker) {
            assertEq(askerAfter, who, "the first asker, or the first watcher after a maker, is recorded");
        } else {
            assertEq(askerAfter, askerBefore, "a re-ask never replaces a watcher");
        }
    }

    function answer(uint256 seed, uint256 out) external steps {
        uint256 id = _pick(seed);
        if (id == 0 || _status(id) != PinkyVault.Status.Asked) return;
        (,,,, uint64 startBlock, uint64 endBlock,,,,,,,, address askedIntake, bytes32 requestId,) = vault.promises(id);
        OracleAttestation.Attestation memory a;
        a.requestId = bytes32(bytes16(keccak256(abi.encode(++nonce))));
        a.chainId = block.chainid;
        a.answerType = 3;
        a.answer = abi.encode(out);
        a.fromBlock = startBlock;
        a.toBlock = endBlock;
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 6;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 86_400);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, vault.attestationDigest(a));
        MockIntake(askedIntake).complete(requestId, a, abi.encodePacked(r, s, v));
        verdicts += 1;
    }

    function payout(uint256 seed) external steps {
        uint256 id = _pick(seed);
        if (id == 0) return;
        PinkyVault.Status s = _status(id);
        (address maker,,, uint256 bond,,,,,,,, bool paid, address asker,,,) = vault.promises(id);
        if (paid || (s != PinkyVault.Status.Kept && s != PinkyVault.Status.Broken)) return;
        uint256 askerBefore = imd.balanceOf(asker);
        uint256 stakingBefore = imd.balanceOf(address(staking));
        uint256 burnBefore = imd.balanceOf(vault.BURN());
        uint256 makerBefore = imd.balanceOf(maker);
        vault.payout(id);
        if (s == PinkyVault.Status.Kept) {
            assertEq(imd.balanceOf(maker) - makerBefore, bond, "a kept promise returns the whole bond");
            toMakers += bond;
        } else {
            assertEq(imd.balanceOf(maker), makerBefore, "a broken promise returns nothing");
            uint256 bounty = imd.balanceOf(asker) - askerBefore;
            uint256 shared = imd.balanceOf(address(staking)) - stakingBefore;
            uint256 burnt = imd.balanceOf(vault.BURN()) - burnBefore;
            assertEq(bounty, asker == maker ? 0 : bond / 10, "the bounty is a tenth, or nothing for the maker");
            assertLe(shared, (bond - bounty) / 2, "stakers get at most half the remainder");
            assertEq(bounty + shared + burnt, bond, "a broken bond is split without remainder");
            toAskers += bounty;
            toStakers += shared;
            burned += burnt;
        }
    }

    function refund(uint256 seed) external steps {
        uint256 id = _pick(seed);
        if (id == 0) return;
        PinkyVault.Status s = _status(id);
        (,,, uint256 bond,,,, uint64 closedAt, uint64 askedAt, uint8 attempts,,,,,,) = vault.promises(id);
        if (s != PinkyVault.Status.Closed && s != PinkyVault.Status.Asked) return;
        if (s == PinkyVault.Status.Asked && vm.getBlockTimestamp() < askedAt + vault.ANSWER_TIMEOUT()) return;
        if (attempts < vault.MAX_ATTEMPTS() && vm.getBlockTimestamp() < closedAt + vault.REFUND_GRACE()) return;
        vault.refund(id);
        toMakers += bond;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
contract PinkyInvariantTest is Test {
    PinkyVault vault;
    PinkyStaking staking;
    MockERC20 imd;
    PinkyHandler handler;

    function setUp() public {
        vm.warp(1_790_000_000);
        vm.roll(1_000);
        imd = new MockERC20("Identity.md", "IMD");
        MockERC20 pinky = new MockERC20("Pinky", "PINKY");
        MockERC20 token = new MockERC20("Meme", "MEME");
        MockIntake intake = new MockIntake(address(0xFEE), 0.5 ether);
        staking = new PinkyStaking(address(pinky), address(imd));
        vault = new PinkyVault(
            address(this),
            address(imd),
            address(staking),
            address(intake),
            bytes32("oracle.request@oracle-1"),
            vm.addr(0xA11CE),
            5 ether,
            7,
            5,
            86_400
        );
        handler = new PinkyHandler(vault, staking, imd, pinky, token, intake);
        targetContract(address(handler));
    }

    /// @notice The vault holds exactly the bonds it still owes, never more and never less.
    function invariant_VaultHoldsExactlyTheOpenBonds() public view {
        uint256 open;
        for (uint256 id = 1; id <= vault.count(); ++id) {
            (,,, uint256 bond,,,,,,,,,,,,) = vault.promises(id);
            open += bond;
        }
        assertEq(imd.balanceOf(address(vault)), open);
    }

    /// @notice Every IMD that entered went to the oracle, a maker, an asker, stakers or the burn.
    function invariant_EveryTokenIsAccountedFor() public view {
        assertEq(
            handler.deposited(),
            imd.balanceOf(address(vault)) + handler.toIntake() + handler.toMakers() + handler.toAskers()
                + handler.toStakers() + handler.burned()
        );
    }

    /// @notice A promise that was paid or refunded keeps no bond, and the vault keeps no allowance.
    function invariant_SettledPromisesAreEmpty() public view {
        for (uint256 id = 1; id <= vault.count(); ++id) {
            (,,, uint256 bond,,,,,,, PinkyVault.Status status, bool paid,,,,) = vault.promises(id);
            if (paid || status == PinkyVault.Status.Refunded) assertEq(bond, 0);
        }
        assertEq(imd.allowance(address(vault), address(staking)), 0);
    }

    /// @notice Until it is settled, a bond is exactly the deposit less the oracle fee each ask paid
    /// at the price it found, and no promise is asked more than three times.
    function invariant_BondIsTheDepositLessTheFeesPaid() public view {
        for (uint256 id = 1; id <= vault.count(); ++id) {
            (,,, uint256 bond,,,,,, uint8 attempts, PinkyVault.Status status, bool paid,,,,) = vault.promises(id);
            assertLe(attempts, vault.MAX_ATTEMPTS());
            if (!paid && status != PinkyVault.Status.Refunded) {
                assertEq(bond, handler.bondAt(id) - handler.feesPaid(id));
            }
            assertLe(handler.feesPaid(id), handler.bondAt(id), "fees never exceed the deposit");
            if (status == PinkyVault.Status.Active || status == PinkyVault.Status.Closed) assertEq(attempts, 0);
            if (
                status == PinkyVault.Status.Asked || status == PinkyVault.Status.Kept
                    || status == PinkyVault.Status.Broken
            ) {
                assertGe(attempts, 1);
            }
        }
    }

    /// @notice A promise never goes backwards: the handler checks each transition, and here the
    /// count of promises with a verdict equals the verdicts delivered.
    function invariant_VerdictsAreFinal() public view {
        uint256 settled;
        for (uint256 id = 1; id <= vault.count(); ++id) {
            (,,,,,,,,,, PinkyVault.Status status,, address asker,,,) = vault.promises(id);
            if (status == PinkyVault.Status.Kept || status == PinkyVault.Status.Broken) {
                settled += 1;
                assertTrue(asker != address(0), "a verdict without an asker");
            }
            assertEq(uint8(status), uint8(handler.lastStatus(id)), "the handler's view is current");
        }
        assertEq(settled, handler.verdicts());
    }
}
