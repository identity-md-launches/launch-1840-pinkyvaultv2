// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {IIntake} from "./interfaces/IIntake.sol";

interface IPinkyStaking {
    function totalStaked() external view returns (uint256);
    function notify(uint256 amount) external;
}

/// @notice A deployer bonds IMD behind a promise not to move more than `maxOut` of a token out of
/// their wallet before a deadline. When the term ends the IdentityMD oracle sums the wallet's
/// outgoing Transfer events over the exact block range, paid for out of the bond. A kept promise
/// returns the bond; a broken one is split between the caller who asked, PINKY stakers and a burn.
contract PinkyVault is OracleAttestationConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;

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
        uint256 maxOut;
        /// @dev IMD still held for this promise. Oracle fees come out of it.
        uint256 bond;
        uint64 startBlock;
        uint64 endBlock;
        uint64 endTime;
        uint64 closedAt;
        uint64 askedAt;
        uint8 attempts;
        Status status;
        bool paid;
        address asker;
        address intake;
        bytes32 requestId;
        uint256 observedOut;
    }

    /// @dev What a promise was bought under: the Intake, action and oracle price seen at `make`,
    /// and the smallest panel any of its `ask`s paid for, which the answer is checked against
    /// rather than the owner's current settings. The Intake and action the promise was made under
    /// may move their price and the bond pays it; any other Intake or action the owner sets later
    /// is capped at `maxPrice`, so a bond cannot be routed through a greedy one.
    struct Terms {
        uint256 maxPrice;
        uint16 panelSize;
        uint16 quorum;
        address intake;
        bytes32 action;
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

    event ProtocolSet(address indexed intake, bytes32 action);
    event PanelSet(uint16 panelSize, uint16 quorum, uint32 validForSeconds);
    event Made(
        uint256 indexed id,
        address indexed maker,
        address indexed token,
        uint256 maxOut,
        uint256 bond,
        uint64 startBlock,
        uint64 endTime
    );
    event Closed(uint256 indexed id, uint64 endBlock);
    event Asked(uint256 indexed id, address indexed asker, bytes32 indexed requestId, uint256 price);
    event Verdict(uint256 indexed id, bytes32 indexed oracleRequestId, bool kept, uint256 observedOut);
    event Paid(uint256 indexed id, uint256 toMaker, uint256 bounty, uint256 toStakers, uint256 burned);
    event Refunded(uint256 indexed id, uint256 amount);

    uint256 public constant MIN_DURATION = 10 minutes;
    uint256 public constant MAX_DURATION = 30 days;
    /// @dev The oracle wants a closing block at least five behind the head.
    uint256 public constant SETTLE_DELAY_BLOCKS = 32;
    uint256 public constant ANSWER_TIMEOUT = 1 days;
    uint256 public constant REFUND_GRACE = 7 days;
    uint8 public constant MAX_ATTEMPTS = 3;
    uint256 public constant BOUNTY_BPS = 1_000;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    address private constant ARB_SYS = address(100);

    address public immutable owner;
    IERC20 public immutable imd;
    IPinkyStaking public immutable staking;
    uint256 public immutable minBond;

    IIntake public intake;
    bytes32 public action;
    uint16 public panelSize;
    uint16 public quorum;
    uint32 public validForSeconds;
    uint256 public count;
    mapping(uint256 => Promise) public promises;
    mapping(uint256 => Terms) public terms;
    mapping(address => mapping(bytes32 => uint256)) public promiseIdFor;

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
        staking = IPinkyStaking(staking_);
        minBond = minBond_;
        _setProtocol(intake_, action_);
        _setPanel(panelSize_, quorum_, validForSeconds_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @notice Bonds `bond` IMD behind the caller's own wallet for `duration` seconds.
    function make(address token, uint256 maxOut, uint256 duration, uint256 bond)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (token.code.length == 0 || token == address(imd)) revert InvalidPromise();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidPromise();
        IIntake intake_ = intake;
        bytes32 action_ = action;
        uint256 price = intake_.priceOf(action_, address(imd));
        // The Intake quotes 0 for an action it does not sell, and `ask` refuses a zero price, so a
        // promise made under one could never be settled: refuse it here, as `ask` would.
        if (price == 0) revert InvalidPayment();
        if (bond < minBond || bond < price * MAX_ATTEMPTS) revert BondTooSmall();

        uint256 balanceBefore = imd.balanceOf(address(this));
        imd.safeTransferFrom(msg.sender, address(this), bond);
        if (imd.balanceOf(address(this)) != balanceBefore + bond) revert InvalidPayment();

        id = ++count;
        Promise storage v = promises[id];
        v.maker = msg.sender;
        v.token = token;
        v.maxOut = maxOut;
        v.bond = bond;
        v.startBlock = uint64(_chainBlock());
        v.endTime = uint64(block.timestamp + duration);
        Terms storage t = terms[id];
        t.maxPrice = price;
        t.intake = address(intake_);
        t.action = action_;
        emit Made(id, msg.sender, token, maxOut, bond, v.startBlock, v.endTime);
    }

    /// @notice Fixes the block the term ends at. Until someone calls it the term keeps running.
    function close(uint256 id) external nonReentrant {
        Promise storage v = _promise(id);
        if (v.status != Status.Active) revert WrongStatus();
        if (block.timestamp < v.endTime) revert TooEarly();
        v.status = Status.Closed;
        v.endBlock = uint64(_chainBlock());
        v.closedAt = uint64(block.timestamp);
        emit Closed(id, v.endBlock);
    }

    /// @notice Buys the oracle's answer for a closed promise out of its bond.
    /// @dev Asking again after the timeout does not kill the earlier request: every request this
    /// promise paid for stays answerable until a verdict lands, and the first answer wins. The
    /// asker is whoever asked first, unless that was the maker, who earns no bounty.
    function ask(uint256 id) external nonReentrant returns (bytes32 requestId) {
        Promise storage v = _promise(id);
        if (v.status == Status.Asked) {
            if (block.timestamp < uint256(v.askedAt) + ANSWER_TIMEOUT) revert TooEarly();
        } else if (v.status != Status.Closed) {
            revert WrongStatus();
        }
        if (_chainBlock() < uint256(v.endBlock) + SETTLE_DELAY_BLOCKS) revert TooEarly();
        if (v.attempts >= MAX_ATTEMPTS) revert NoAttemptsLeft();

        IIntake intake_ = intake;
        bytes32 action_ = action;
        Terms storage t = terms[id];
        uint256 price = intake_.priceOf(action_, address(imd));
        if (price == 0 || price > v.bond) revert InvalidPayment();
        // The Intake and action the promise was made under may have moved their price since, and
        // the bond pays it. Any other Intake or action the owner has set is held to the price the
        // promise was made under, so a bond cannot be routed through a greedy one.
        bool sameProtocol = address(intake_) == t.intake && action_ == t.action;
        if (!sameProtocol && price > t.maxPrice) revert InvalidPayment();

        v.status = Status.Asked;
        v.attempts += 1;
        v.bond -= price;
        v.askedAt = uint64(block.timestamp);
        if (v.asker == address(0) || v.asker == v.maker) v.asker = msg.sender;
        v.intake = address(intake_);
        // An answer to any request this promise paid for counts, so the check uses the smallest
        // panel any of them asked for.
        if (t.panelSize == 0 || panelSize < t.panelSize) t.panelSize = panelSize;
        if (t.quorum == 0 || quorum < t.quorum) t.quorum = quorum;

        uint256 balanceBefore = imd.balanceOf(address(this));
        imd.forceApprove(address(intake_), price);
        requestId = intake_.request(
            action_,
            _body(v, panelSize, quorum),
            IIntake.Callback(address(this), this.onOracleResult.selector),
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

    /// @notice The Intake's callback. Records the verdict and moves no funds.
    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        uint256 id = promiseIdFor[msg.sender][requestId];
        if (id == 0) revert UnknownRequest();
        Promise storage v = promises[id];
        if (v.status != Status.Asked) revert WrongStatus();
        _verifyAttestation(a, signature);
        Terms storage t = terms[id];
        if (
            a.chainId != block.chainid || a.fromBlock != v.startBlock || a.toBlock != v.endBlock
                || a.panelSize < t.panelSize || a.quorum < t.quorum || a.quorum > a.panelSize || a.agreed < a.quorum
        ) revert InvalidAttestation();
        if (a.answer.length != 32) revert InvalidAttestation();
        uint256 out = decodeUint256(a);
        _consume(a.requestId);
        delete promiseIdFor[msg.sender][requestId];

        bool kept = out <= v.maxOut;
        v.status = kept ? Status.Kept : Status.Broken;
        v.observedOut = out;
        emit Verdict(id, a.requestId, kept, out);
    }

    /// @notice Pays out a promise that has its verdict. Anyone may call.
    function payout(uint256 id) external nonReentrant {
        Promise storage v = _promise(id);
        if (v.status != Status.Kept && v.status != Status.Broken) revert WrongStatus();
        if (v.paid) revert AlreadyPaid();
        v.paid = true;
        uint256 amount = v.bond;
        v.bond = 0;

        if (v.status == Status.Kept) {
            imd.safeTransfer(v.maker, amount);
            emit Paid(id, amount, 0, 0, 0);
            return;
        }
        // The bounty pays a watcher. A maker who asked about their own broken promise gets none.
        uint256 bounty = v.asker == v.maker ? 0 : amount * BOUNTY_BPS / 10_000;
        uint256 rest = amount - bounty;
        uint256 toStakers = rest / 2;
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
        uint256 burned = rest - toStakers;
        if (bounty != 0) imd.safeTransfer(v.asker, bounty);
        if (burned != 0) imd.safeTransfer(BURN, burned);
        emit Paid(id, 0, bounty, toStakers, burned);
    }

    /// @notice Returns what is left of the bond when the oracle gave no answer in time.
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

    function setProtocol(address intake_, bytes32 action_) external onlyOwner nonReentrant {
        _setProtocol(intake_, action_);
    }

    function setSigner(address signer_) external onlyOwner nonReentrant {
        _setOracleSigner(signer_);
    }

    function setPanel(uint16 panelSize_, uint16 quorum_, uint32 validForSeconds_) external onlyOwner nonReentrant {
        _setPanel(panelSize_, quorum_, validForSeconds_);
    }

    /// @notice The oracle body `ask` would send for this promise once it is closed.
    function bodyOf(uint256 id) external view returns (string memory) {
        return string(_body(_promise(id), panelSize, quorum));
    }

    function _body(Promise storage v, uint16 panelSize_, uint16 quorum_) private view returns (bytes memory) {
        return bytes(
            string.concat(
                '{"v":1,"question":"What is the sum of the value argument of every Transfer(address indexed from, address indexed to, uint256 value) event emitted by the token contract ',
                Strings.toHexString(v.token),
                " whose from argument is ",
                Strings.toHexString(v.maker),
                ' in the window?","chainId":',
                Strings.toString(block.chainid),
                ',"window":{"fromBlock":',
                Strings.toString(v.startBlock),
                ',"toBlock":',
                Strings.toString(v.endBlock),
                '},"answerType":"uint256","evidence":"chain","definitions":{"recipe":"{\\"kind\\":\\"log-sum\\",\\"address\\":\\"',
                Strings.toHexString(v.token),
                '\\",\\"event\\":\\"event Transfer(address indexed from, address indexed to, uint256 value)\\",\\"sumArg\\":\\"value\\",\\"abs\\":false,\\"filter\\":{\\"from\\":\\"',
                Strings.toHexString(v.maker),
                '\\"}} - write recipe exactly this, event text included."},"panelSize":',
                Strings.toString(panelSize_),
                ',"quorum":',
                Strings.toString(quorum_),
                ',"toleranceBps":0,"validForSeconds":',
                Strings.toString(validForSeconds),
                "}"
            )
        );
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
        intake = IIntake(intake_);
        action = action_;
        emit ProtocolSet(intake_, action_);
    }

    function _setPanel(uint16 panelSize_, uint16 quorum_, uint32 validForSeconds_) private {
        if (
            panelSize_ < 2 || panelSize_ > 100 || quorum_ < 2 || quorum_ > panelSize_ || validForSeconds_ < 60
                || validForSeconds_ > 30 days
        ) revert InvalidConfiguration();
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
