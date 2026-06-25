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

    /**
     * @notice Open a stream that pays `recipient_` `deposit_` tokens linearly over `duration_` seconds.
     * @dev Pulls `deposit_` from the caller, who must approve this contract first.
     * @param token_ ERC-20 to stream.
     * @param recipient_ Address that will receive the stream.
     * @param deposit_ Total amount to lock and stream (must be > 0).
     * @param duration_ Stream length in seconds (must be > 0).
     * @return streamId The id of the new stream.
     */
    function createStream(address token_, address recipient_, uint256 deposit_, uint64 duration_)
        external
        returns (uint256 streamId)
    {
        if (token_ == address(0) || recipient_ == address(0)) revert ZeroAddress();
        if (recipient_ == msg.sender) revert CannotStreamToSelf();
        if (deposit_ == 0) revert ZeroDeposit();
        if (duration_ == 0) revert ZeroDuration();

        uint64 start = uint64(block.timestamp);
        uint64 stop = start + duration_;

        streamId = _nextStreamId++;
        _streams[streamId] = Stream({
            sender: msg.sender,
            recipient: recipient_,
            token: token_,
            deposit: deposit_,
            withdrawn: 0,
            startTime: start,
            stopTime: stop,
            active: true
        });

        emit StreamCreated(streamId, msg.sender, recipient_, token_, deposit_, start, stop);

        IERC20(token_).safeTransferFrom(msg.sender, address(this), deposit_);
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
     * @dev Either the sender or the recipient can cancel. Settles and pays both sides in one call.
     * @param streamId_ The stream to cancel.
     */
    function cancel(uint256 streamId_) external nonReentrant {
        Stream storage s = _streams[streamId_];
        if (s.sender == address(0)) revert StreamNotFound();
        if (!s.active) revert StreamNotActive();
        if (msg.sender != s.sender && msg.sender != s.recipient) revert NotStreamParty();

        uint256 streamed = _streamedAmount(s);
        uint256 recipientPayout = streamed - s.withdrawn; // accrued but not yet withdrawn
        uint256 senderRefund = s.deposit - streamed; // not yet streamed

        // Settle before moving any funds.
        s.active = false;
        s.withdrawn = s.deposit;

        address token = s.token;
        address recipient = s.recipient;
        address sender = s.sender;

        emit StreamCancelled(streamId_, sender, recipient, senderRefund, recipientPayout);

        if (recipientPayout > 0) IERC20(token).safeTransfer(recipient, recipientPayout);
        if (senderRefund > 0) IERC20(token).safeTransfer(sender, senderRefund);
    }

    /// @notice Total tokens that have accrued to the recipient so far (withdrawn or not).
    function streamedAmount(uint256 streamId_) public view returns (uint256) {
        Stream memory s = _streams[streamId_];
        if (s.sender == address(0)) revert StreamNotFound();
        return _streamedAmount(s);
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
