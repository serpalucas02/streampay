// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title StreamPay
 * @author Lucas Serpa
 * @notice Real-time token payments: lock an ERC-20 amount and "stream" it to a
 *         recipient linearly over time. The recipient can withdraw whatever has
 *         accrued at any moment, and either party can cancel and split the rest fairly.
 * @dev Works with any ERC-20 (the payer picks the token). The accrued amount is
 *      computed on read as deposit * elapsed / duration, so it lands exactly on the
 *      deposit at stopTime — no rounding dust. Funds move via SafeERC20 under strict
 *      CEI + ReentrancyGuard, and withdrawals follow the pull pattern.
 */
contract StreamPay is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroDeposit();
    error ZeroDuration();
    error CannotStreamToSelf();
    error StreamNotFound();
    error StreamNotActive();
    error NotStreamRecipient();
    error NotStreamParty();
    error NothingToWithdraw();
    error NothingToClaim();

    struct Stream {
        address sender; // who funds the stream
        address recipient; // who receives it
        address token; // ERC-20 being streamed
        uint256 deposit; // total tokens locked
        uint256 withdrawn; // total already pulled by the recipient
        uint64 startTime;
        uint64 stopTime;
        bool active; // false once cancelled or fully settled
    }

    uint256 private _nextStreamId = 1;
    mapping(uint256 streamId => Stream) private _streams;
    // Funds owed to an account per token (credited on cancel, pulled via claim()).
    mapping(address account => mapping(address token => uint256)) private _claimable;

    event StreamCreated(
        uint256 indexed streamId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 deposit,
        uint64 startTime,
        uint64 stopTime
    );
    event Withdrawn(uint256 indexed streamId, address indexed recipient, uint256 amount);
    event StreamCancelled(
        uint256 indexed streamId,
        address indexed sender,
        address indexed recipient,
        uint256 senderRefund,
        uint256 recipientPayout
    );
    event Claimed(address indexed account, address indexed token, uint256 amount);

    /**
     * @notice Open a stream that pays `recipient_` `deposit_` tokens linearly over `duration_` seconds.
     * @dev Pulls `deposit_` from the caller (who must approve first) and records the
     *      amount actually received, so fee-on-transfer tokens can't make the contract
     *      over-account (which would let one stream draw on another's funds). Rebasing
     *      tokens whose balance changes after the deposit are not supported.
     * @param token_ ERC-20 to stream.
     * @param recipient_ Address that will receive the stream.
     * @param deposit_ Amount to pull from the caller (must be > 0; the recorded deposit
     *        is the amount actually received).
     * @param duration_ Stream length in seconds (must be > 0).
     * @return streamId The id of the new stream.
     */
    function createStream(address token_, address recipient_, uint256 deposit_, uint64 duration_)
        external
        nonReentrant
        returns (uint256 streamId)
    {
        if (token_ == address(0) || recipient_ == address(0)) revert ZeroAddress();
        if (recipient_ == msg.sender) revert CannotStreamToSelf();
        if (deposit_ == 0) revert ZeroDeposit();
        if (duration_ == 0) revert ZeroDuration();

        // Pull first and measure what really arrived. nonReentrant keeps the
        // balance reading honest even if the token has transfer hooks.
        IERC20 token = IERC20(token_);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), deposit_);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroDeposit();

        uint64 start = uint64(block.timestamp);
        uint64 stop = start + duration_;

        streamId = _nextStreamId++;
        _streams[streamId] = Stream({
            sender: msg.sender,
            recipient: recipient_,
            token: token_,
            deposit: received,
            withdrawn: 0,
            startTime: start,
            stopTime: stop,
            active: true
        });

        emit StreamCreated(streamId, msg.sender, recipient_, token_, received, start, stop);
    }

    /**
     * @notice Withdraw everything that has accrued so far on a stream.
     * @dev Only the recipient can withdraw. Follows CEI + pull pattern.
     * @param streamId_ The stream to withdraw from.
     */
    function withdraw(uint256 streamId_) external nonReentrant {
        Stream storage s = _streams[streamId_];
        if (s.sender == address(0)) revert StreamNotFound();
        if (!s.active) revert StreamNotActive();
        if (msg.sender != s.recipient) revert NotStreamRecipient();

        uint256 amount = _streamedAmount(s) - s.withdrawn;
        if (amount == 0) revert NothingToWithdraw();

        s.withdrawn += amount;
        if (s.withdrawn == s.deposit) s.active = false; // fully streamed and pulled

        emit Withdrawn(streamId_, s.recipient, amount);

        IERC20(s.token).safeTransfer(s.recipient, amount);
    }

    /**
     * @notice Cancel a stream: the recipient keeps what has accrued, the sender gets the rest back.
     * @dev Either the sender or the recipient can cancel. Settlement *credits* each party's
     *      claimable balance instead of transferring here, so a token that reverts for one side
     *      (e.g. a blacklist) can never block the other. cancel makes no external calls; both
     *      sides pull independently via claim().
     * @param streamId_ The stream to cancel.
     */
    function cancel(uint256 streamId_) external {
        Stream storage s = _streams[streamId_];
        if (s.sender == address(0)) revert StreamNotFound();
        if (!s.active) revert StreamNotActive();
        if (msg.sender != s.sender && msg.sender != s.recipient) revert NotStreamParty();

        uint256 streamed = _streamedAmount(s);
        uint256 recipientPayout = streamed - s.withdrawn; // accrued but not yet withdrawn
        uint256 senderRefund = s.deposit - streamed; // not yet streamed

        // `withdrawn` becomes the recipient's lifetime receipts; `active = false` blocks any
        // further action on this stream.
        s.active = false;
        s.withdrawn = streamed;

        if (recipientPayout > 0) _claimable[s.recipient][s.token] += recipientPayout;
        if (senderRefund > 0) _claimable[s.sender][s.token] += senderRefund;

        emit StreamCancelled(streamId_, s.sender, s.recipient, senderRefund, recipientPayout);
    }

    /**
     * @notice Pull everything credited to you for a token (e.g. your side of a cancelled stream).
     * @dev Pull pattern with CEI + ReentrancyGuard, so each party claims independently.
     * @param token_ The token to claim.
     * @return amount The amount transferred to the caller.
     */
    function claim(address token_) external nonReentrant returns (uint256 amount) {
        amount = _claimable[msg.sender][token_];
        if (amount == 0) revert NothingToClaim();
        _claimable[msg.sender][token_] = 0;
        emit Claimed(msg.sender, token_, amount);
        IERC20(token_).safeTransfer(msg.sender, amount);
    }

    /// @notice Amount credited to `account_` for `token_`, withdrawable via claim().
    function claimable(address account_, address token_) external view returns (uint256) {
        return _claimable[account_][token_];
    }

    /// @notice Total tokens that have accrued to the recipient so far (withdrawn or not).
    /// @dev Once a stream is settled, `withdrawn` is the final total — don't keep accruing by time.
    function streamedAmount(uint256 streamId_) public view returns (uint256) {
        Stream memory s = _streams[streamId_];
        if (s.sender == address(0)) revert StreamNotFound();
        return s.active ? _streamedAmount(s) : s.withdrawn;
    }

    /// @notice Tokens the recipient can withdraw right now (accrued minus already withdrawn).
    function withdrawableAmount(uint256 streamId_) public view returns (uint256) {
        Stream memory s = _streams[streamId_];
        if (s.sender == address(0)) revert StreamNotFound();
        if (!s.active) return 0;
        return _streamedAmount(s) - s.withdrawn;
    }

    /// @notice Full data of a stream.
    function getStream(uint256 streamId_) external view returns (Stream memory) {
        Stream memory s = _streams[streamId_];
        if (s.sender == address(0)) revert StreamNotFound();
        return s;
    }

    /// @dev Linear accrual: 0 before start, full deposit at/after stop, proportional in between.
    function _streamedAmount(Stream memory s) private view returns (uint256) {
        if (block.timestamp <= s.startTime) return 0;
        if (block.timestamp >= s.stopTime) return s.deposit;

        uint256 elapsed = block.timestamp - s.startTime;
        uint256 duration = s.stopTime - s.startTime;
        // mulDiv keeps full precision and can't overflow on the intermediate product.
        return Math.mulDiv(s.deposit, elapsed, duration);
    }
}
