// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StreamPay} from "../src/StreamPay.sol";
import {MockToken} from "../src/MockToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract StreamPayTest is Test {
    StreamPay stream;
    MockToken token;

    address alice = makeAddr("alice"); // sender / payer
    address bob = makeAddr("bob"); // recipient
    address carol = makeAddr("carol"); // unrelated third party

    uint256 constant DEPOSIT = 1000 ether;
    uint64 constant DURATION = 1000; // seconds -> 1 token/sec, easy to reason about

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
    event Claimed(address indexed account, address indexed token, uint256 amount);
    event StreamCancelled(
        uint256 indexed streamId,
        address indexed sender,
        address indexed recipient,
        uint256 senderRefund,
        uint256 recipientPayout
    );

    function setUp() public {
        stream = new StreamPay();
        token = new MockToken("Stream Test USD", "sUSD");
        token.mint(alice, 1_000_000 ether);
    }

    function _create() internal returns (uint256 id) {
        vm.startPrank(alice);
        token.approve(address(stream), DEPOSIT);
        id = stream.createStream(address(token), bob, DEPOSIT, DURATION);
        vm.stopPrank();
    }

    // --- createStream ---

    function testCreateStreamStoresData() public {
        uint256 id = _create();
        StreamPay.Stream memory s = stream.getStream(id);
        assertEq(s.sender, alice);
        assertEq(s.recipient, bob);
        assertEq(s.token, address(token));
        assertEq(s.deposit, DEPOSIT);
        assertEq(s.withdrawn, 0);
        assertEq(s.stopTime - s.startTime, DURATION);
        assertTrue(s.active);
    }

    function testCreateStreamPullsFunds() public {
        uint256 aliceBefore = token.balanceOf(alice);
        _create();
        assertEq(token.balanceOf(address(stream)), DEPOSIT, "contract holds the deposit");
        assertEq(token.balanceOf(alice), aliceBefore - DEPOSIT, "deposit left alice");
    }

    function testCreateStreamIncrementsIds() public {
        assertEq(_create(), 1);
        assertEq(_create(), 2);
    }

    function testCreateStreamEmits() public {
        vm.startPrank(alice);
        token.approve(address(stream), DEPOSIT);
        vm.expectEmit(true, true, true, true, address(stream));
        emit StreamCreated(1, alice, bob, address(token), DEPOSIT, uint64(block.timestamp), uint64(block.timestamp) + DURATION);
        stream.createStream(address(token), bob, DEPOSIT, DURATION);
        vm.stopPrank();
    }

    function testCreateRevertsZeroToken() public {
        vm.prank(alice);
        vm.expectRevert(StreamPay.ZeroAddress.selector);
        stream.createStream(address(0), bob, DEPOSIT, DURATION);
    }

    function testCreateRevertsZeroRecipient() public {
        vm.prank(alice);
        vm.expectRevert(StreamPay.ZeroAddress.selector);
        stream.createStream(address(token), address(0), DEPOSIT, DURATION);
    }

    function testCreateRevertsToSelf() public {
        vm.prank(alice);
        vm.expectRevert(StreamPay.CannotStreamToSelf.selector);
        stream.createStream(address(token), alice, DEPOSIT, DURATION);
    }

    function testCreateRevertsZeroDeposit() public {
        vm.prank(alice);
        vm.expectRevert(StreamPay.ZeroDeposit.selector);
        stream.createStream(address(token), bob, 0, DURATION);
    }

    function testCreateRevertsZeroDuration() public {
        vm.prank(alice);
        vm.expectRevert(StreamPay.ZeroDuration.selector);
        stream.createStream(address(token), bob, DEPOSIT, 0);
    }

    function testCreateRevertsWithoutApproval() public {
        vm.prank(alice); // no approve() first
        vm.expectRevert();
        stream.createStream(address(token), bob, DEPOSIT, DURATION);
    }

    function testCreateRevertsWithInsufficientBalance() public {
        uint256 tooMuch = 2_000_000 ether; // alice was minted only 1,000,000
        vm.startPrank(alice);
        token.approve(address(stream), tooMuch);
        vm.expectRevert(); // ERC20InsufficientBalance from the token
        stream.createStream(address(token), bob, tooMuch, DURATION);
        vm.stopPrank();
    }

    function testCreateRecordsActualReceivedForFeeToken() public {
        FeeToken fee = new FeeToken(1000); // 10% fee on transfer
        fee.mint(alice, DEPOSIT);

        vm.startPrank(alice);
        fee.approve(address(stream), DEPOSIT);
        uint256 id = stream.createStream(address(fee), bob, DEPOSIT, DURATION);
        vm.stopPrank();

        // The contract records what ACTUALLY arrived (900), not what was requested (1000).
        assertEq(stream.getStream(id).deposit, 900 ether, "records received, not requested");
        assertEq(fee.balanceOf(address(stream)), 900 ether, "holds exactly what it accounted");

        // At the end the recipient withdraws the full recorded amount and the contract
        // empties out completely — no shortfall that could touch another stream's funds.
        vm.warp(block.timestamp + DURATION);
        vm.prank(bob);
        stream.withdraw(id);
        assertEq(fee.balanceOf(bob), 810 ether, "got 900 minus the 10% transfer fee");
        assertEq(fee.balanceOf(address(stream)), 0, "contract fully settled, nothing stuck or borrowed");
    }

    function testCreateRevertsIfNothingReceived() public {
        FeeToken fee = new FeeToken(10000); // 100% fee -> contract receives nothing
        fee.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        fee.approve(address(stream), DEPOSIT);
        vm.expectRevert(StreamPay.ZeroDeposit.selector);
        stream.createStream(address(fee), bob, DEPOSIT, DURATION);
        vm.stopPrank();
    }

    // The core safety property: one stream can never touch another's funds.
    function testMultipleStreamsAreIsolated() public {
        vm.startPrank(alice);
        token.approve(address(stream), DEPOSIT + 500 ether);
        uint256 id1 = stream.createStream(address(token), bob, DEPOSIT, DURATION); // 1000 to bob
        uint256 id2 = stream.createStream(address(token), carol, 500 ether, DURATION); // 500 to carol
        vm.stopPrank();
        uint64 startT = stream.getStream(id1).startTime; // stable across vm.warp
        assertEq(token.balanceOf(address(stream)), DEPOSIT + 500 ether);

        vm.warp(startT + 500); // halfway
        vm.prank(bob);
        stream.withdraw(id1);
        assertEq(token.balanceOf(bob), 500 ether);
        assertEq(stream.withdrawableAmount(id2), 250 ether, "carol's stream is untouched by bob's withdraw");

        vm.prank(alice);
        stream.cancel(id1); // credits alice the unstreamed 500

        vm.warp(startT + DURATION); // carol's stream reaches the end
        vm.prank(carol);
        stream.withdraw(id2);
        assertEq(token.balanceOf(carol), 500 ether, "carol still gets her full deposit");

        vm.prank(alice);
        stream.claim(address(token)); // alice pulls her refund
        assertEq(token.balanceOf(address(stream)), 0, "everything settled, no funds stuck or borrowed");
    }

    // --- accrual (streamedAmount / withdrawableAmount) ---

    function testStreamedAmountProgression() public {
        uint256 id = _create();
        uint64 start = stream.getStream(id).startTime;
        assertEq(stream.streamedAmount(id), 0, "nothing at start");

        vm.warp(start + 500);
        assertEq(stream.streamedAmount(id), 500 ether, "half way");

        vm.warp(start + DURATION); // exactly at stop
        assertEq(stream.streamedAmount(id), DEPOSIT, "full at stop");

        vm.warp(start + DURATION + 5000); // long after stop
        assertEq(stream.streamedAmount(id), DEPOSIT, "capped at deposit");
    }

    function testWithdrawableMatchesAccruedMinusWithdrawn() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 300);
        assertEq(stream.withdrawableAmount(id), 300 ether);

        vm.prank(bob);
        stream.withdraw(id);
        assertEq(stream.withdrawableAmount(id), 0, "nothing left right after withdrawing");
    }

    function testStreamedRevertsNotFound() public {
        vm.expectRevert(StreamPay.StreamNotFound.selector);
        stream.streamedAmount(999);
    }

    function testWithdrawableRevertsNotFound() public {
        vm.expectRevert(StreamPay.StreamNotFound.selector);
        stream.withdrawableAmount(999);
    }

    // --- withdraw ---

    function testWithdrawHappy() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 500);

        vm.prank(bob);
        stream.withdraw(id);

        assertEq(token.balanceOf(bob), 500 ether, "bob got the accrued half");
        assertEq(token.balanceOf(address(stream)), 500 ether, "the rest stays locked");
        assertEq(stream.getStream(id).withdrawn, 500 ether);
    }

    function testWithdrawEmits() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 500);
        vm.expectEmit(true, true, false, true, address(stream));
        emit Withdrawn(id, bob, 500 ether);
        vm.prank(bob);
        stream.withdraw(id);
    }

    function testWithdrawFullAtEndSettlesStream() public {
        uint256 id = _create();
        vm.warp(block.timestamp + DURATION);

        vm.prank(bob);
        stream.withdraw(id);
        assertEq(token.balanceOf(bob), DEPOSIT);
        assertFalse(stream.getStream(id).active, "stream settled after full withdrawal");

        // a second withdraw must fail since it's settled
        vm.prank(bob);
        vm.expectRevert(StreamPay.StreamNotActive.selector);
        stream.withdraw(id);
    }

    function testWithdrawRevertsIfNotRecipient() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 500);
        vm.prank(carol);
        vm.expectRevert(StreamPay.NotStreamRecipient.selector);
        stream.withdraw(id);
    }

    function testWithdrawRevertsNothingToWithdraw() public {
        uint256 id = _create(); // no time elapsed
        vm.prank(bob);
        vm.expectRevert(StreamPay.NothingToWithdraw.selector);
        stream.withdraw(id);
    }

    function testWithdrawRevertsNotFound() public {
        vm.prank(bob);
        vm.expectRevert(StreamPay.StreamNotFound.selector);
        stream.withdraw(999);
    }

    // --- cancel ---

    function testCancelBySenderMidStream() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 400);

        vm.prank(alice);
        stream.cancel(id);

        // cancel credits both sides (no transfers); funds stay put until each party claims.
        assertEq(stream.claimable(bob, address(token)), 400 ether, "recipient credited the accrued part");
        assertEq(stream.claimable(alice, address(token)), 600 ether, "sender credited the remainder");
        assertEq(token.balanceOf(address(stream)), DEPOSIT, "nothing moved yet");
        assertFalse(stream.getStream(id).active);
        assertEq(stream.getStream(id).withdrawn, 400 ether, "withdrawn = recipient's lifetime receipts");
        assertEq(stream.streamedAmount(id), 400 ether, "streamedAmount frozen at the settled total");

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(bob);
        stream.claim(address(token));
        vm.prank(alice);
        stream.claim(address(token));
        assertEq(token.balanceOf(bob), 400 ether, "recipient pulled the accrued part");
        assertEq(token.balanceOf(alice), aliceBefore + 600 ether, "sender pulled the remainder");
        assertEq(token.balanceOf(address(stream)), 0, "contract emptied once both claimed");
    }

    function testCancelByRecipientWorks() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 400);
        vm.prank(bob);
        stream.cancel(id);
        assertEq(stream.claimable(bob, address(token)), 400 ether);

        vm.prank(bob);
        stream.claim(address(token));
        assertEq(token.balanceOf(bob), 400 ether);
    }

    function testCancelAtStartCreditsFullRefund() public {
        uint256 id = _create(); // no time elapsed
        vm.prank(alice);
        stream.cancel(id);
        assertEq(stream.claimable(alice, address(token)), DEPOSIT, "full refund credited to sender");
        assertEq(stream.claimable(bob, address(token)), 0, "recipient credited nothing");
    }

    function testCancelEmits() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 400);
        vm.expectEmit(true, true, true, true, address(stream));
        emit StreamCancelled(id, alice, bob, 600 ether, 400 ether);
        vm.prank(alice);
        stream.cancel(id);
    }

    function testCancelAfterPartialWithdraw() public {
        uint256 id = _create();
        uint64 startT = stream.getStream(id).startTime; // stored value is stable across vm.warp

        vm.warp(startT + 300);
        vm.prank(bob);
        stream.withdraw(id); // bob pulls 300 directly (active stream)
        assertEq(token.balanceOf(bob), 300 ether);

        vm.warp(startT + 500); // 500 streamed total
        vm.prank(alice);
        stream.cancel(id);
        assertEq(stream.claimable(bob, address(token)), 200 ether, "remaining accrued credited");
        assertEq(stream.claimable(alice, address(token)), 500 ether, "unstreamed credited to sender");

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(bob);
        stream.claim(address(token));
        vm.prank(alice);
        stream.claim(address(token));
        assertEq(token.balanceOf(bob), 500 ether, "300 withdrawn + 200 claimed");
        assertEq(token.balanceOf(alice), aliceBefore + 500 ether);
        assertEq(token.balanceOf(address(stream)), 0);
    }

    function testCancelAfterStopGivesAllToRecipient() public {
        uint256 id = _create();
        vm.warp(block.timestamp + DURATION + 100);

        vm.prank(alice);
        stream.cancel(id);

        assertEq(stream.claimable(bob, address(token)), DEPOSIT, "recipient credited everything");
        assertEq(stream.claimable(alice, address(token)), 0, "sender credited nothing");
    }

    function testCancelRevertsForThirdParty() public {
        uint256 id = _create();
        vm.prank(carol);
        vm.expectRevert(StreamPay.NotStreamParty.selector);
        stream.cancel(id);
    }

    function testCancelRevertsNotFound() public {
        vm.prank(alice);
        vm.expectRevert(StreamPay.StreamNotFound.selector);
        stream.cancel(999);
    }

    function testCancelRevertsIfAlreadySettled() public {
        uint256 id = _create();
        vm.prank(alice);
        stream.cancel(id);

        vm.prank(alice);
        vm.expectRevert(StreamPay.StreamNotActive.selector);
        stream.cancel(id);
    }

    function testWithdrawableIsZeroAfterCancel() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 400);
        vm.prank(alice);
        stream.cancel(id);
        assertEq(stream.withdrawableAmount(id), 0);
    }

    // --- claim (pull settlement) ---

    function testClaimRevertsWhenNothingToClaim() public {
        vm.prank(bob);
        vm.expectRevert(StreamPay.NothingToClaim.selector);
        stream.claim(address(token));
    }

    function testClaimPaysAndZeroesOut() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 400);
        vm.prank(alice);
        stream.cancel(id);

        vm.expectEmit(true, true, false, true, address(stream));
        emit Claimed(bob, address(token), 400 ether);
        vm.prank(bob);
        stream.claim(address(token));

        assertEq(token.balanceOf(bob), 400 ether);
        assertEq(stream.claimable(bob, address(token)), 0, "claim zeroes the balance");

        // claiming again has nothing left
        vm.prank(bob);
        vm.expectRevert(StreamPay.NothingToClaim.selector);
        stream.claim(address(token));
    }

    /// @dev The whole point of pull settlement: a blacklisted recipient can't trap the cancel
    ///      or the sender's refund.
    function testCancelAndRefundUnblockedByBlacklistedRecipient() public {
        BlacklistToken bl = new BlacklistToken();
        bl.mint(alice, DEPOSIT);
        bl.setBlocked(bob, true); // bob can't receive this token

        vm.startPrank(alice);
        bl.approve(address(stream), DEPOSIT);
        uint256 id = stream.createStream(address(bl), bob, DEPOSIT, DURATION);
        vm.stopPrank();

        vm.warp(block.timestamp + 400);

        // cancel must succeed even though the recipient is blacklisted (it makes no transfers)
        vm.prank(alice);
        stream.cancel(id);

        // the sender pulls their refund — not blocked by the blacklisted recipient
        vm.prank(alice);
        stream.claim(address(bl));
        assertEq(bl.balanceOf(alice), 600 ether, "sender recovered the unstreamed funds");

        // only the blacklisted recipient's own claim fails, affecting nobody else
        vm.prank(bob);
        vm.expectRevert();
        stream.claim(address(bl));
    }

    // --- getStream ---

    function testGetStreamRevertsNotFound() public {
        vm.expectRevert(StreamPay.StreamNotFound.selector);
        stream.getStream(999);
    }

    // --- security: reentrancy ---

    function testReentrancyGuardBlocksMaliciousToken() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, DEPOSIT);

        vm.startPrank(alice);
        evil.approve(address(stream), DEPOSIT);
        uint256 id = stream.createStream(address(evil), bob, DEPOSIT, DURATION);
        vm.stopPrank();

        vm.warp(block.timestamp + 500);
        evil.arm(stream, id); // token will try to reenter withdraw() on transfer

        vm.prank(bob);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        stream.withdraw(id);
    }

    // --- fuzz ---

    function testFuzzAccrualNeverExceedsDeposit(uint256 deposit_, uint64 duration_, uint64 elapsed_) public {
        deposit_ = bound(deposit_, 1, 1_000_000 ether);
        duration_ = uint64(bound(duration_, 1, 365 days));
        elapsed_ = uint64(bound(elapsed_, 0, 2 * 365 days));

        token.mint(alice, deposit_);
        vm.startPrank(alice);
        token.approve(address(stream), deposit_);
        uint256 id = stream.createStream(address(token), bob, deposit_, duration_);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed_);
        uint256 streamed = stream.streamedAmount(id);
        assertLe(streamed, deposit_, "never streams more than deposited");
        if (elapsed_ >= duration_) assertEq(streamed, deposit_, "exactly the deposit once the stream ends");
    }
}

/// @dev ERC-20 whose transfer hook reenters StreamPay.withdraw() to test the guard.
contract ReentrantToken is ERC20 {
    StreamPay private _target;
    uint256 private _attackId;
    bool private _armed;

    constructor() ERC20("Evil", "EVL") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }

    function arm(StreamPay target_, uint256 attackId_) external {
        _target = target_;
        _attackId = attackId_;
        _armed = true;
    }

    function _update(address from_, address to_, uint256 value_) internal override {
        super._update(from_, to_, value_);
        if (_armed) {
            _armed = false; // one shot
            _target.withdraw(_attackId); // should revert via ReentrancyGuard
        }
    }
}

/// @dev ERC-20 that charges a fee on every transfer, to test fee-on-transfer accounting.
contract FeeToken is ERC20 {
    uint256 private immutable _feeBps;

    constructor(uint256 feeBps_) ERC20("Fee", "FEE") {
        _feeBps = feeBps_;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }

    function _update(address from_, address to_, uint256 value_) internal override {
        if (from_ == address(0) || to_ == address(0)) {
            super._update(from_, to_, value_); // no fee on mint / burn
            return;
        }
        uint256 fee = (value_ * _feeBps) / 10000;
        super._update(from_, to_, value_ - fee);
        super._update(from_, address(0xdEaD), fee);
    }
}

/// @dev ERC-20 that blocks transfers to/from blacklisted addresses (USDC-style), to test that
///      pull settlement keeps one party's freeze from trapping the other.
contract BlacklistToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Blacklist", "BLK") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }

    function setBlocked(address account_, bool value_) external {
        blocked[account_] = value_;
    }

    function _update(address from_, address to_, uint256 value_) internal override {
        require(!blocked[from_] && !blocked[to_], "blacklisted");
        super._update(from_, to_, value_);
    }
}
