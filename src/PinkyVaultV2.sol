// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {IIntakeV2} from "./interfaces/IIntakeV2.sol";

/// @dev Where the fee goes. PinkyStaking has exactly this: it pulls `amount` from the caller and
/// streams it to stakers. A later contract with the same function can take its place.
interface IFeeSink {
    function notify(uint256 amount) external;
}

interface IStakingPool {
    function totalStaked() external view returns (uint256);
    function notify(uint256 amount) external;
}

/// @notice Pinky, second vault. A holder bonds IMD behind one of four promises about their own
/// wallet, optionally made to someone. When the term ends the IdentityMD oracle answers the
/// promise's question over the exact block range, paid for out of the bond:
///
///  - Keep:  the wallet will not send more than `amount` of `token` out (log-sum, from = maker).
///  - Pay:   the wallet will send at least `amount` of `token` to `target` (log-sum, from and to).
///  - Hold:  at the end the wallet will still hold at least `amount` of `token` (call-compare on
///           balanceOf at the closing block). Works for any contract with balanceOf(address),
///           NFTs included. Checked once, at the end: what happens in between is not seen.
///  - Moves: the wallet will make no more than `amount` transfers of `token` out (log-count,
///           from = maker). Meant for NFTs, where one transfer is one token.
///
/// The window runs from the block of `make` to the block of `close`, which the maker may call at
/// the deadline and anyone two minutes later; the oracle is asked 32 blocks after that.
///
/// A kept promise returns the bond to the maker less a 1% fee. A broken promise made to a
/// beneficiary pays the beneficiary the bond less the same fee; one made to nobody is split as in
/// the first vault: 10% to the first watcher who asked, half the rest to PINKY stakers, the rest
/// burned. Fees accrue here and are sent to the fee sink, PinkyStaking at launch, by anyone.
///
/// Questions go through the Intake's version 2, which also reports a refusal or a panel that did not
/// agree. Such a report is unsigned, so it moves no money: it only lets anyone ask again at once
/// instead of after a day.
///
/// The owner can change the oracle's Intake and action, its signer, the panel and the fee sink,
/// each only through a proposal that takes effect after seven days, in the open.
contract PinkyVaultV2 is OracleAttestationConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Kind {
        Keep,
        Pay,
        Hold,
        Moves
    }

    enum Status {
        Active,
        Closed,
        Asked,
        Kept,
        Broken,
        Refunded
    }

    struct Promise {
        address maker;
        address token;
        Kind kind;
        Status status;
        uint8 attempts;
        bool paid;
        /// @dev Keep, Moves: the most that may leave. Pay, Hold: the least that must arrive or stay.
        uint256 amount;
        /// @dev Pay: who the tokens must reach. Zero for the other kinds.
        address target;
        /// @dev Who a broken promise pays. Zero: nobody in particular, and the public split applies.
        address beneficiary;
        /// @dev IMD still held for this promise. Oracle fees come out of it.
        uint256 bond;
        uint64 startBlock;
        uint64 endBlock;
        uint64 endTime;
        uint64 closedAt;
        uint64 askedAt;
        address asker;
        address intake;
        bytes32 requestId;
        /// @dev What the oracle counted: the sum, the number of transfers, or the balance compared.
        uint256 observed;
        /// @dev The Intake reported that the latest request ended without an answer.
        bool failed;
    }

    /// @dev What a promise was bought under, as in the first vault: the Intake, action and price
    /// seen at `make`, the smallest panel any of its requests paid for, and the signer at its
    /// latest `ask`, whose answer stays acceptable if the owner rotates the signer meanwhile.
    struct Terms {
        uint256 maxPrice;
        uint16 panelSize;
        uint16 quorum;
        address intake;
        bytes32 action;
        address signer;
    }

    /// @dev A setting change waiting out its delay. `eta` zero: nothing pending.
    struct Pending {
        bytes32 data;
        bytes32 extra;
        uint64 eta;
    }

    error OnlyOwner();
    error InvalidConfiguration();
    error InvalidPromise();
    error BondTooSmall();
    error InvalidPayment();
    error UnknownPromise();
    error UnknownRequest();
    error WrongStatus();
    error TooEarly();
    error NoAttemptsLeft();
    error DuplicateRequest();
    error InvalidAttestation();
    error AlreadyPaid();
    error NothingPending();
    error NotAParty();

    event Made(
        uint256 indexed id,
        address indexed maker,
        address indexed token,
        Kind kind,
        uint256 amount,
        address target,
        address beneficiary,
        uint256 bond,
        uint64 startBlock,
        uint64 endTime
    );
    event Closed(uint256 indexed id, uint64 endBlock);
    event Asked(uint256 indexed id, address indexed asker, bytes32 indexed requestId, uint256 price);
    event Verdict(uint256 indexed id, bytes32 indexed oracleRequestId, bool kept, uint256 observed);
    /// @dev `status` 1: refused, 2: no result. `agreed` of `answered` panel members gave the leading answer.
    event AskFailed(
        uint256 indexed id, bytes32 indexed requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered
    );
    event Paid(
        uint256 indexed id,
        uint256 toMaker,
        uint256 toBeneficiary,
        uint256 bounty,
        uint256 toStakers,
        uint256 burned,
        uint256 fee
    );
    event Refunded(uint256 indexed id, uint256 amount);
    event FeesSent(address indexed sink, uint256 amount);
    event Proposed(Setting indexed setting, bytes32 data, bytes32 extra, uint64 eta);
    event Cancelled(Setting indexed setting);
    event ProtocolSet(address indexed intake, bytes32 action);
    event PanelSet(uint16 panelSize, uint16 quorum, uint32 validForSeconds);
    event FeeSinkSet(address indexed sink);

    enum Setting {
        Protocol,
        Signer,
        Panel,
        FeeSink
    }

    uint256 public constant MIN_DURATION = 10 minutes;
    uint256 public constant MAX_DURATION = 30 days;
    /// @dev The window ends at the block that closes it, so it covers every block of the term on
    /// any chain, one that mints a block only when a transaction arrives included. The oracle wants
    /// that closing block confirmed, so the ask waits this many blocks after it, as in the first
    /// vault. On Robinhood Chain that is a few seconds while there are transactions.
    uint256 public constant SETTLE_DELAY_BLOCKS = 32;
    /// @dev The maker may close from the deadline itself; anyone else this much later. A maker who
    /// closes on time is judged on the term alone, and nobody else can stretch the window first.
    uint256 public constant CLOSE_GRACE = 2 minutes;
    uint256 public constant ANSWER_TIMEOUT = 1 days;
    uint256 public constant REFUND_GRACE = 7 days;
    uint8 public constant MAX_ATTEMPTS = 3;
    uint256 public constant BOUNTY_BPS = 1_000;
    uint256 public constant FEE_BPS = 100;
    uint256 public constant SETTINGS_DELAY = 7 days;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    address private constant ARB_SYS = address(100);

    address public immutable owner;
    IERC20 public immutable imd;
    IStakingPool public immutable staking;
    uint256 public immutable minBond;

    IIntakeV2 public intake;
    bytes32 public action;
    uint16 public panelSize;
    uint16 public quorum;
    uint32 public validForSeconds;
    IFeeSink public feeSink;
    /// @dev Fees taken from payouts and not yet sent to the sink.
    uint256 public fees;
    uint256 public count;
    mapping(uint256 => Promise) public promises;
    mapping(uint256 => Terms) public terms;
    mapping(address => mapping(bytes32 => uint256)) public promiseIdFor;
    mapping(Setting => Pending) public pending;

    constructor(
        address owner_,
        address imd_,
        address staking_,
        address intake_,
        bytes32 action_,
        address signer_,
        uint256 minBond_,
        uint16 panelSize_,
        uint16 quorum_,
        uint32 validForSeconds_
    ) OracleAttestationConsumer(signer_) {
        if (owner_ == address(0) || imd_ == address(0) || staking_ == address(0) || minBond_ == 0) {
            revert InvalidConfiguration();
        }
        owner = owner_;
        imd = IERC20(imd_);
        staking = IStakingPool(staking_);
        minBond = minBond_;
        _setProtocol(intake_, action_);
        _setPanel(panelSize_, quorum_, validForSeconds_);
        // The fee goes to PINKY stakers until the owner proposes something else.
        feeSink = IFeeSink(staking_);
        emit FeeSinkSet(staking_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // ───────────────────────── promises ─────────────────────────

    /// @notice Bonds `bond` IMD behind a promise about the caller's own wallet for `duration` seconds.
    /// @param target Pay only: who the tokens must reach. Zero for every other kind.
    /// @param beneficiary Who a broken promise pays, or zero for the public split.
    function make(
        Kind kind,
        address token,
        uint256 amount,
        address target,
        address beneficiary,
        uint256 duration,
        uint256 bond
    ) external nonReentrant returns (uint256 id) {
        if (token.code.length == 0) revert InvalidPromise();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidPromise();
        if (beneficiary == msg.sender || beneficiary == address(this)) revert InvalidPromise();
        if (kind == Kind.Pay) {
            // Paying yourself or the vault proves nothing; paying nothing is not a promise.
            if (target == address(0) || target == msg.sender || target == address(this) || amount == 0) {
                revert InvalidPromise();
            }
        } else {
            if (target != address(0)) revert InvalidPromise();
            // The bond itself leaves the wallet as IMD in this block, inside the window.
            if ((kind == Kind.Keep || kind == Kind.Moves) && token == address(imd)) revert InvalidPromise();
            if (kind == Kind.Hold && amount == 0) revert InvalidPromise();
        }

        IIntakeV2 intake_ = intake;
        bytes32 action_ = action;
        uint256 price = intake_.priceOf(action_, address(imd));
        // A promise made while the Intake sells nothing could never be settled.
        if (price == 0) revert InvalidPayment();
        if (bond < minBond || bond < price * MAX_ATTEMPTS) revert BondTooSmall();

        uint256 balanceBefore = imd.balanceOf(address(this));
        imd.safeTransferFrom(msg.sender, address(this), bond);
        if (imd.balanceOf(address(this)) != balanceBefore + bond) revert InvalidPayment();

        id = ++count;
        Promise storage v = promises[id];
        v.maker = msg.sender;
        v.token = token;
        v.kind = kind;
        v.amount = amount;
        v.target = target;
        v.beneficiary = beneficiary;
        v.bond = bond;
        v.startBlock = uint64(_chainBlock());
        v.endTime = uint64(block.timestamp + duration);
        Terms storage t = terms[id];
        t.maxPrice = price;
        t.intake = address(intake_);
        t.action = action_;
        emit Made(id, msg.sender, token, kind, amount, target, beneficiary, bond, v.startBlock, v.endTime);
    }

    /// @notice Ends the term when it is still running, and asks the oracle once it has ended.
    /// Anyone may call: the maker from the deadline, anyone else two minutes later. The window
    /// ends at the block that closes it, and the oracle wants that block confirmed, so the ask is a
    /// second call 32 blocks later; a call that only closed returns zero.
    function settle(uint256 id) external nonReentrant returns (bytes32 requestId) {
        Promise storage v = _promise(id);
        if (v.status == Status.Active) {
            _close(id);
            return 0;
        }
        if (v.status != Status.Closed) revert WrongStatus();
        requestId = _ask(id);
    }

    /// @notice Ends the term and fixes the block the window ends at. The bond can be refunded after
    /// the grace period if nobody asks.
    function close(uint256 id) external nonReentrant {
        _close(id);
    }

    /// @notice Asks for a closed promise, or again when the last request failed or went unanswered
    /// for a day.
    /// @dev Every request this promise paid for stays answerable until a verdict lands or the Intake
    /// reports it failed. The asker is whoever asked first, unless that was the maker, who earns no
    /// bounty. Once the bond could be refunded, only the maker or the beneficiary may ask again.
    function ask(uint256 id) external nonReentrant returns (bytes32 requestId) {
        Promise storage v = _promise(id);
        if (v.status == Status.Asked) {
            if (!v.failed && block.timestamp < uint256(v.askedAt) + ANSWER_TIMEOUT) revert TooEarly();
        } else if (v.status != Status.Closed) {
            revert WrongStatus();
        }
        requestId = _ask(id);
    }

    /// @notice The Intake's callback. Records the verdict and moves no funds.
    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        uint256 id = promiseIdFor[msg.sender][requestId];
        if (id == 0) revert UnknownRequest();
        Promise storage v = promises[id];
        if (v.status != Status.Asked) revert WrongStatus();
        Terms storage t = terms[id];
        _verifyAttestationFrom(t.signer, a, signature);
        if (
            a.chainId != block.chainid || a.fromBlock != v.startBlock || a.toBlock != v.endBlock
                || a.panelSize < t.panelSize || a.quorum < t.quorum || a.quorum > a.panelSize || a.agreed < a.quorum
        ) revert InvalidAttestation();
        if (a.answer.length != 32) revert InvalidAttestation();

        bool kept;
        uint256 observed;
        if (v.kind == Kind.Hold) {
            kept = decodeBool(a);
            observed = a.figure;
        } else {
            observed = decodeUint256(a);
            kept = v.kind == Kind.Pay ? observed >= v.amount : observed <= v.amount;
        }
        _consume(a.requestId);
        delete promiseIdFor[msg.sender][requestId];

        v.status = kept ? Status.Kept : Status.Broken;
        v.observed = observed;
        emit Verdict(id, a.requestId, kept, observed);
    }

    /// @notice The Intake's report that a request was refused (status 1) or ended without a result
    /// (status 2). Unsigned, so it moves no funds and decides nothing: it forgets that request and,
    /// if it was the latest, lets anyone ask again without waiting a day. Refunds keep their wait.
    function onOracleFailure(
        bytes32 requestId,
        uint8 status,
        bytes32 reason,
        uint16 agreed,
        uint16 answered,
        bytes calldata
    ) external nonReentrant {
        uint256 id = promiseIdFor[msg.sender][requestId];
        if (id == 0) revert UnknownRequest();
        Promise storage v = promises[id];
        if (v.status != Status.Asked) revert WrongStatus();
        delete promiseIdFor[msg.sender][requestId];
        if (requestId == v.requestId) v.failed = true;
        emit AskFailed(id, requestId, status, reason, agreed, answered);
    }

    /// @notice Pays out a promise that has its verdict. Anyone may call.
    function payout(uint256 id) external nonReentrant {
        Promise storage v = _promise(id);
        if (v.status != Status.Kept && v.status != Status.Broken) revert WrongStatus();
        if (v.paid) revert AlreadyPaid();
        v.paid = true;
        uint256 amount = v.bond;
        v.bond = 0;

        if (v.status == Status.Kept || v.beneficiary != address(0)) {
            uint256 fee = amount * FEE_BPS / 10_000;
            fees += fee;
            uint256 rest = amount - fee;
            if (v.status == Status.Kept) {
                imd.safeTransfer(v.maker, rest);
                emit Paid(id, rest, 0, 0, 0, 0, fee);
            } else {
                imd.safeTransfer(v.beneficiary, rest);
                emit Paid(id, 0, rest, 0, 0, 0, fee);
            }
            return;
        }

        // Broken, made to nobody: the first vault's split. No fee on top.
        uint256 bounty = v.asker == v.maker ? 0 : amount * BOUNTY_BPS / 10_000;
        uint256 left = amount - bounty;
        uint256 toStakers = left / 2;
        if (toStakers == 0 || staking.totalStaked() == 0) {
            toStakers = 0;
        } else {
            imd.forceApprove(address(staking), toStakers);
            try staking.notify(toStakers) {}
            catch {
                toStakers = 0;
            }
            imd.forceApprove(address(staking), 0);
        }
        uint256 burned = left - toStakers;
        if (bounty != 0) imd.safeTransfer(v.asker, bounty);
        if (burned != 0) imd.safeTransfer(BURN, burned);
        emit Paid(id, 0, 0, bounty, toStakers, burned, 0);
    }

    /// @notice Returns what is left of the bond when the oracle gave no answer in time. No fee.
    function refund(uint256 id) external nonReentrant {
        Promise storage v = _promise(id);
        if (v.status == Status.Asked) {
            if (block.timestamp < uint256(v.askedAt) + ANSWER_TIMEOUT) revert TooEarly();
            delete promiseIdFor[v.intake][v.requestId];
        } else if (v.status != Status.Closed) {
            revert WrongStatus();
        }
        if (v.attempts < MAX_ATTEMPTS && block.timestamp < uint256(v.closedAt) + REFUND_GRACE) revert TooEarly();
        v.status = Status.Refunded;
        uint256 amount = v.bond;
        v.bond = 0;
        imd.safeTransfer(v.maker, amount);
        emit Refunded(id, amount);
    }

    /// @notice Sends the fees taken so far to the fee sink. Anyone may call. If the sink refuses
    /// (PinkyStaking does while nobody is staked), the fees stay here for the next try. A sink that
    /// takes less than the fees without refusing makes this call revert instead, and keep reverting
    /// until a new sink is enacted; the fees wait here either way.
    function sendFees() external nonReentrant {
        uint256 amount = fees;
        if (amount == 0) return;
        IFeeSink sink = feeSink;
        fees = 0;
        imd.forceApprove(address(sink), amount);
        uint256 balanceBefore = imd.balanceOf(address(this));
        try sink.notify(amount) {
            // The sink must have taken exactly the fees, and nothing that belongs to a bond.
            if (balanceBefore - imd.balanceOf(address(this)) != amount) revert InvalidPayment();
            emit FeesSent(address(sink), amount);
        } catch {
            fees = amount;
        }
        imd.forceApprove(address(sink), 0);
    }

    // ───────────────────────── settings, behind a delay ─────────────────────────

    /// @dev The constructor cannot check for code (it runs on an empty chain in the launch checks);
    /// a proposal can, and an Intake without code would stop `make` and `ask` for a week.
    function proposeProtocol(address intake_, bytes32 action_) external onlyOwner {
        if (intake_.code.length == 0 || action_ == bytes32(0)) revert InvalidConfiguration();
        _propose(Setting.Protocol, bytes32(uint256(uint160(intake_))), action_);
    }

    function proposeSigner(address signer_) external onlyOwner {
        if (signer_ == address(0)) revert InvalidConfiguration();
        _propose(Setting.Signer, bytes32(uint256(uint160(signer_))), 0);
    }

    function proposePanel(uint16 panelSize_, uint16 quorum_, uint32 validForSeconds_) external onlyOwner {
        _checkPanel(panelSize_, quorum_, validForSeconds_);
        _propose(Setting.Panel, bytes32(uint256(panelSize_) << 48 | uint256(quorum_) << 32 | validForSeconds_), 0);
    }

    function proposeFeeSink(address sink_) external onlyOwner {
        if (sink_.code.length == 0) revert InvalidConfiguration();
        _propose(Setting.FeeSink, bytes32(uint256(uint160(sink_))), 0);
    }

    function cancel(Setting setting) external onlyOwner {
        if (pending[setting].eta == 0) revert NothingPending();
        delete pending[setting];
        emit Cancelled(setting);
    }

    /// @notice Applies a proposal once its delay has passed. Anyone may call.
    function enact(Setting setting) external nonReentrant {
        Pending memory p = pending[setting];
        if (p.eta == 0) revert NothingPending();
        if (block.timestamp < p.eta) revert TooEarly();
        delete pending[setting];
        if (setting == Setting.Protocol) {
            _setProtocol(address(uint160(uint256(p.data))), p.extra);
        } else if (setting == Setting.Signer) {
            _setOracleSigner(address(uint160(uint256(p.data))));
        } else if (setting == Setting.Panel) {
            uint256 packed = uint256(p.data);
            _setPanel(uint16(packed >> 48), uint16(packed >> 32), uint32(packed));
        } else {
            feeSink = IFeeSink(address(uint160(uint256(p.data))));
            emit FeeSinkSet(address(feeSink));
        }
    }

    // ───────────────────────── reading ─────────────────────────

    /// @notice The oracle body `ask` would send for this promise once it is closed.
    function bodyOf(uint256 id) external view returns (string memory) {
        return string(_body(_promise(id), panelSize, quorum));
    }

    // ───────────────────────── inside ─────────────────────────

    function _close(uint256 id) private {
        Promise storage v = _promise(id);
        if (v.status != Status.Active) revert WrongStatus();
        uint256 due = uint256(v.endTime) + (msg.sender == v.maker ? 0 : CLOSE_GRACE);
        if (block.timestamp < due) revert TooEarly();
        // The window ends at this block, as in the first vault. Nothing earlier is known to lie at
        // or past the deadline: on a chain that mints a block only when a transaction arrives, the
        // block before this one can be from inside the term.
        v.status = Status.Closed;
        v.endBlock = uint64(_chainBlock());
        v.closedAt = uint64(block.timestamp);
        emit Closed(id, v.endBlock);
    }

    function _ask(uint256 id) private returns (bytes32 requestId) {
        Promise storage v = promises[id];
        if (_chainBlock() < uint256(v.endBlock) + SETTLE_DELAY_BLOCKS) revert TooEarly();
        if (v.attempts >= MAX_ATTEMPTS) revert NoAttemptsLeft();
        // Once the bond could be refunded, only the parties may spend it on another ask: a stranger
        // could otherwise ask in the refund's own block and push the refund back a day, three times.
        if (
            block.timestamp >= uint256(v.closedAt) + REFUND_GRACE && msg.sender != v.maker
                && msg.sender != v.beneficiary
        ) revert NotAParty();

        IIntakeV2 intake_ = intake;
        bytes32 action_ = action;
        Terms storage t = terms[id];
        uint256 price = intake_.priceOf(action_, address(imd));
        if (price == 0 || price > v.bond) revert InvalidPayment();
        // The Intake and action the promise was made under may move their price and the bond pays
        // it. Any other Intake or action set since is held to the price the promise was made under.
        bool sameProtocol = address(intake_) == t.intake && action_ == t.action;
        if (!sameProtocol && price > t.maxPrice) revert InvalidPayment();

        v.status = Status.Asked;
        v.failed = false;
        v.attempts += 1;
        v.bond -= price;
        v.askedAt = uint64(block.timestamp);
        if (v.asker == address(0) || v.asker == v.maker) v.asker = msg.sender;
        v.intake = address(intake_);
        t.signer = oracleSigner;
        if (t.panelSize == 0 || panelSize < t.panelSize) t.panelSize = panelSize;
        if (t.quorum == 0 || quorum < t.quorum) t.quorum = quorum;

        uint256 balanceBefore = imd.balanceOf(address(this));
        imd.forceApprove(address(intake_), price);
        requestId = intake_.requestWithFailure(
            action_,
            _body(v, panelSize, quorum),
            IIntakeV2.Callback(address(this), this.onOracleResult.selector),
            this.onOracleFailure.selector,
            address(imd),
            price
        );
        imd.forceApprove(address(intake_), 0);
        if (imd.balanceOf(address(this)) + price != balanceBefore) revert InvalidPayment();
        if (promiseIdFor[address(intake_)][requestId] != 0) revert DuplicateRequest();

        v.requestId = requestId;
        promiseIdFor[address(intake_)][requestId] = id;
        emit Asked(id, msg.sender, requestId, price);
    }

    function _body(Promise storage v, uint16 panelSize_, uint16 quorum_) private view returns (bytes memory) {
        (string memory question, string memory recipe, string memory answerType) = _question(v);
        return bytes(
            string.concat(
                '{"v":1,"question":"',
                question,
                '","chainId":',
                Strings.toString(block.chainid),
                ',"window":{"fromBlock":',
                Strings.toString(v.startBlock),
                ',"toBlock":',
                Strings.toString(v.endBlock),
                '},"answerType":"',
                answerType,
                '","evidence":"chain","definitions":{"recipe":"',
                recipe,
                ' - write recipe exactly this, event text included."},"panelSize":',
                Strings.toString(panelSize_),
                ',"quorum":',
                Strings.toString(quorum_),
                ',"toleranceBps":0,"validForSeconds":',
                Strings.toString(validForSeconds),
                "}"
            )
        );
    }

    /// @dev The question, its recipe (already escaped for a JSON string) and the answer type.
    /// Recipes are the shapes the oracle has attested on Robinhood Chain.
    function _question(Promise storage v)
        private
        view
        returns (string memory question, string memory recipe, string memory answerType)
    {
        string memory token = Strings.toHexString(v.token);
        string memory maker = Strings.toHexString(v.maker);
        if (v.kind == Kind.Hold) {
            string memory threshold = Strings.toString(v.amount);
            question = string.concat(
                "At the last block of the window, is balanceOf(",
                maker,
                ") on the contract ",
                token,
                " greater than or equal to ",
                threshold,
                "?"
            );
            recipe = string.concat(
                '{\\"kind\\":\\"call-compare\\",\\"to\\":\\"',
                token,
                '\\",\\"function\\":\\"function balanceOf(address) view returns (uint256)\\",\\"args\\":[\\"',
                maker,
                '\\"],\\"op\\":\\">=\\",\\"threshold\\":\\"',
                threshold,
                '\\"}'
            );
            return (question, recipe, "bool");
        }
        if (v.kind == Kind.Moves) {
            question = string.concat(
                "How many Transfer(address indexed from, address indexed to, uint256 indexed tokenId) events emitted by the contract ",
                token,
                " have a from argument equal to ",
                maker,
                " in the window?"
            );
            recipe = string.concat(
                '{\\"kind\\":\\"log-count\\",\\"address\\":\\"',
                token,
                '\\",\\"event\\":\\"event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)\\",\\"filter\\":{\\"from\\":\\"',
                maker,
                '\\"}}'
            );
            return (question, recipe, "uint256");
        }
        string memory toPart;
        string memory toFilter;
        if (v.kind == Kind.Pay) {
            string memory to = Strings.toHexString(v.target);
            toPart = string.concat(" and whose to argument is ", to);
            toFilter = string.concat(',\\"to\\":\\"', to, '\\"');
        }
        question = string.concat(
            "What is the sum of the value argument of every Transfer(address indexed from, address indexed to, uint256 value) event emitted by the token contract ",
            token,
            " whose from argument is ",
            maker,
            toPart,
            " in the window?"
        );
        recipe = string.concat(
            '{\\"kind\\":\\"log-sum\\",\\"address\\":\\"',
            token,
            '\\",\\"event\\":\\"event Transfer(address indexed from, address indexed to, uint256 value)\\",\\"sumArg\\":\\"value\\",\\"abs\\":false,\\"filter\\":{\\"from\\":\\"',
            maker,
            '\\"',
            toFilter,
            "}}"
        );
        return (question, recipe, "uint256");
    }

    /// @dev `_verifyAttestation`, also accepting the signer the request was bought under when the
    /// owner has rotated it since: a rotation applies to requests bought after it, and the answer
    /// to one already in flight, signed by the key it was bought under, is not lost with its fee.
    function _verifyAttestationFrom(
        address boughtUnder,
        OracleAttestation.Attestation calldata a,
        bytes calldata signature
    ) private view {
        address current = oracleSigner;
        if (boughtUnder == current || boughtUnder == address(0)) {
            _verifyAttestation(a, signature);
            return;
        }
        // The same checks as `_verifyAttestation`, over either key.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > a.expiresAt) revert AttestationExpired(a.expiresAt);
        // forge-lint: disable-next-line(block-timestamp)
        if (a.issuedAt > block.timestamp + ISSUED_AT_TOLERANCE) revert AttestationNotYetValid(a.issuedAt);
        bytes32 digest = attestationDigest(a);
        if (
            !SignatureChecker.isValidSignatureNowCalldata(boughtUnder, digest, signature)
                && !SignatureChecker.isValidSignatureNowCalldata(current, digest, signature)
        ) revert BadSignature();
    }

    function _propose(Setting setting, bytes32 data, bytes32 extra) private {
        uint64 eta = uint64(block.timestamp + SETTINGS_DELAY);
        pending[setting] = Pending(data, extra, eta);
        emit Proposed(setting, data, extra, eta);
    }

    /// @dev Robinhood Chain is an Arbitrum chain: `block.number` there is the parent chain's, and
    /// the block numbers its RPC and the oracle use come from ArbSys. Elsewhere address 100 has no
    /// code, the call returns nothing, and `block.number` is already the right one.
    function _chainBlock() private view returns (uint256) {
        (bool ok, bytes memory out) = ARB_SYS.staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        if (ok && out.length == 32) return abi.decode(out, (uint256));
        return block.number;
    }

    function _setProtocol(address intake_, bytes32 action_) private {
        if (intake_ == address(0) || action_ == bytes32(0)) revert InvalidConfiguration();
        intake = IIntakeV2(intake_);
        action = action_;
        emit ProtocolSet(intake_, action_);
    }

    function _checkPanel(uint16 panelSize_, uint16 quorum_, uint32 validForSeconds_) private pure {
        if (
            panelSize_ < 2 || panelSize_ > 100 || quorum_ < 2 || quorum_ > panelSize_ || validForSeconds_ < 60
                || validForSeconds_ > 30 days
        ) revert InvalidConfiguration();
    }

    function _setPanel(uint16 panelSize_, uint16 quorum_, uint32 validForSeconds_) private {
        _checkPanel(panelSize_, quorum_, validForSeconds_);
        panelSize = panelSize_;
        quorum = quorum_;
        validForSeconds = validForSeconds_;
        emit PanelSet(panelSize_, quorum_, validForSeconds_);
    }

    function _promise(uint256 id) private view returns (Promise storage v) {
        if (id == 0 || id > count) revert UnknownPromise();
        v = promises[id];
    }
}
