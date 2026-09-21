// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Handshake} from "../src/Handshake.sol";
import {TimeoutEscrow} from "../src/TimeoutEscrow.sol";
import {FalseReturningToken, MockERC20, NoReturnToken, ReentrantToken, RevertingToken} from "./mocks/MockTokens.sol";

/// @notice Behaviour of TimeoutEscrow against the real SHAKE token, plus the hostile-token paths.
contract TimeoutEscrowTest is Test {
    Handshake internal token;
    TimeoutEscrow internal escrow;

    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant AMOUNT = 1_000e18;
    uint64 internal deadline;

    function setUp() public {
        token = new Handshake();
        escrow = new TimeoutEscrow(address(token));

        // A start time well clear of zero, so "before the deadline" is expressible.
        vm.warp(1_700_000_000);
        deadline = uint64(block.timestamp + 7 days);

        token.transfer(buyer, 10_000e18);
        vm.prank(buyer);
        token.approve(address(escrow), type(uint256).max);
    }

    function _open() internal returns (uint256 id) {
        vm.prank(buyer);
        id = escrow.open(seller, AMOUNT, deadline);
    }

    /* ------------------------------------------------------------------ deployment */

    function test_constructorStoresTheTokenAndNothingElse() public view {
        assertEq(address(escrow.token()), address(token));
        assertEq(escrow.escrowCount(), 0);
    }

    function test_revertWhen_constructedWithTheZeroToken() public {
        vm.expectRevert(TimeoutEscrow.ZeroToken.selector);
        new TimeoutEscrow(address(0));
    }

    function test_thereIsNoAdminEntryPoint() public {
        uint256 id = _open();
        string[6] memory signatures = [
            "owner()", "transferOwnership(address)", "setFee(uint256)", "sweep(address)", "withdraw(uint256)", "pause()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(escrow).call(abi.encodeWithSignature(signatures[i], stranger));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(address(escrow)), AMOUNT);
        assertEq(uint256(escrow.getEscrow(id).status), uint256(TimeoutEscrow.Status.Open));
    }

    /* ------------------------------------------------------------------ open */

    function test_openFundsTheEscrowAndRecordsIt() public {
        uint256 buyerBefore = token.balanceOf(buyer);

        vm.expectEmit(true, true, true, true);
        emit TimeoutEscrow.EscrowOpened(0, buyer, seller, AMOUNT, deadline);
        uint256 id = _open();

        assertEq(id, 0);
        assertEq(escrow.escrowCount(), 1);
        assertEq(token.balanceOf(address(escrow)), AMOUNT);
        assertEq(token.balanceOf(buyer), buyerBefore - AMOUNT);

        TimeoutEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(e.buyer, buyer);
        assertEq(e.seller, seller);
        assertEq(e.amount, AMOUNT);
        assertEq(e.deadline, deadline);
        assertEq(uint256(e.status), uint256(TimeoutEscrow.Status.Open));
    }

    function test_openIssuesSequentialIdsAndAccumulatesFunds() public {
        uint256 first = _open();
        uint256 second = _open();

        assertEq(first, 0);
        assertEq(second, 1);
        assertEq(escrow.escrowCount(), 2);
        assertEq(token.balanceOf(address(escrow)), 2 * AMOUNT);
    }

    function test_openAcceptsADeadlineOneSecondAway() public {
        vm.prank(buyer);
        uint256 id = escrow.open(seller, AMOUNT, uint64(block.timestamp + 1));
        assertEq(escrow.getEscrow(id).deadline, uint64(block.timestamp + 1));
    }

    function test_revertWhen_openingForTheZeroSeller() public {
        vm.prank(buyer);
        vm.expectRevert(TimeoutEscrow.InvalidSeller.selector);
        escrow.open(address(0), AMOUNT, deadline);
    }

    function test_revertWhen_openingForYourself() public {
        vm.prank(buyer);
        vm.expectRevert(TimeoutEscrow.InvalidSeller.selector);
        escrow.open(buyer, AMOUNT, deadline);
    }

    function test_revertWhen_openingForZeroTokens() public {
        vm.prank(buyer);
        vm.expectRevert(TimeoutEscrow.ZeroAmount.selector);
        escrow.open(seller, 0, deadline);
    }

    function test_revertWhen_deadlineIsNow() public {
        uint64 now_ = uint64(block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.DeadlineNotInFuture.selector, now_, now_));
        escrow.open(seller, AMOUNT, now_);
    }

    function test_revertWhen_deadlineIsInThePast() public {
        uint64 past = uint64(block.timestamp - 1);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(TimeoutEscrow.DeadlineNotInFuture.selector, past, uint64(block.timestamp))
        );
        escrow.open(seller, AMOUNT, past);
    }

    function test_revertWhen_openingWithoutAllowance() public {
        vm.prank(buyer);
        token.approve(address(escrow), AMOUNT - 1);

        vm.prank(buyer);
        vm.expectRevert(TimeoutEscrow.TokenTransferFailed.selector);
        escrow.open(seller, AMOUNT, deadline);

        assertEq(escrow.escrowCount(), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_revertWhen_openingWithoutBalance() public {
        vm.prank(stranger);
        token.approve(address(escrow), type(uint256).max);

        vm.prank(stranger);
        vm.expectRevert(TimeoutEscrow.TokenTransferFailed.selector);
        escrow.open(seller, AMOUNT, deadline);

        assertEq(escrow.escrowCount(), 0);
    }

    /* ------------------------------------------------------------------ release */

    function test_buyerReleasesBeforeTheDeadline() public {
        uint256 id = _open();

        vm.expectEmit(true, true, true, true);
        emit TimeoutEscrow.EscrowReleased(id, buyer, seller, AMOUNT);
        vm.prank(buyer);
        escrow.release(id);

        assertEq(token.balanceOf(seller), AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(uint256(escrow.getEscrow(id).status), uint256(TimeoutEscrow.Status.Released));
    }

    function test_buyerMayStillReleaseAfterTheDeadlineWhileTheSellerHasNotClaimed() public {
        uint256 id = _open();
        vm.warp(deadline + 30 days);

        vm.prank(buyer);
        escrow.release(id);

        assertEq(token.balanceOf(seller), AMOUNT);
    }

    function test_revertWhen_sellerTriesToRelease() public {
        uint256 id = _open();
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.NotBuyer.selector, id, seller));
        escrow.release(id);
    }

    function test_revertWhen_strangerTriesToRelease() public {
        uint256 id = _open();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.NotBuyer.selector, id, stranger));
        escrow.release(id);
    }

    function test_revertWhen_releasingTwice() public {
        uint256 id = _open();
        vm.startPrank(buyer);
        escrow.release(id);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.EscrowNotOpen.selector, id));
        escrow.release(id);
        vm.stopPrank();

        assertEq(token.balanceOf(seller), AMOUNT);
    }

    function test_revertWhen_actingOnAnUnknownEscrow() public {
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.EscrowNotOpen.selector, 42));
        escrow.release(42);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.EscrowNotOpen.selector, 42));
        escrow.dispute(42);
        vm.stopPrank();

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.EscrowNotOpen.selector, 42));
        escrow.claim(42);
    }

    /* ------------------------------------------------------------------ dispute */

    function test_buyerDisputesAndTheEscrowSplitsEvenly() public {
        uint256 id = _open();

        vm.expectEmit(true, true, true, true);
        emit TimeoutEscrow.EscrowDisputed(id, buyer, seller, AMOUNT / 2, AMOUNT / 2);
        vm.prank(buyer);
        escrow.dispute(id);

        assertEq(token.balanceOf(seller), AMOUNT / 2);
        assertEq(token.balanceOf(buyer), 10_000e18 - AMOUNT + AMOUNT / 2);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(uint256(escrow.getEscrow(id).status), uint256(TimeoutEscrow.Status.Disputed));
    }

    function test_disputeRoundsTheOddUnitToTheSeller() public {
        vm.prank(buyer);
        uint256 id = escrow.open(seller, 3, deadline);

        vm.prank(buyer);
        escrow.dispute(id);

        assertEq(token.balanceOf(seller), 2);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_disputeOfASingleUnitPaysOnlyTheSeller() public {
        vm.prank(buyer);
        uint256 id = escrow.open(seller, 1, deadline);
        uint256 buyerBefore = token.balanceOf(buyer);

        vm.prank(buyer);
        escrow.dispute(id);

        assertEq(token.balanceOf(seller), 1);
        assertEq(token.balanceOf(buyer), buyerBefore);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_disputeIsAllowedOneSecondBeforeTheDeadline() public {
        uint256 id = _open();
        vm.warp(deadline - 1);

        vm.prank(buyer);
        escrow.dispute(id);

        assertEq(uint256(escrow.getEscrow(id).status), uint256(TimeoutEscrow.Status.Disputed));
    }

    function test_revertWhen_disputingExactlyAtTheDeadline() public {
        uint256 id = _open();
        vm.warp(deadline);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.DeadlinePassed.selector, id, deadline));
        escrow.dispute(id);
    }

    function test_revertWhen_disputingAfterTheDeadline() public {
        uint256 id = _open();
        vm.warp(deadline + 1);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.DeadlinePassed.selector, id, deadline));
        escrow.dispute(id);
    }

    function test_revertWhen_sellerTriesToDispute() public {
        uint256 id = _open();
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.NotBuyer.selector, id, seller));
        escrow.dispute(id);
    }

    function test_revertWhen_disputingAfterRelease() public {
        uint256 id = _open();
        vm.startPrank(buyer);
        escrow.release(id);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.EscrowNotOpen.selector, id));
        escrow.dispute(id);
        vm.stopPrank();
    }

    function test_revertWhen_disputingTwice() public {
        uint256 id = _open();
        vm.startPrank(buyer);
        escrow.dispute(id);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.EscrowNotOpen.selector, id));
        escrow.dispute(id);
        vm.stopPrank();
    }

    /* ------------------------------------------------------------------ claim */

    function test_sellerClaimsExactlyAtTheDeadline() public {
        uint256 id = _open();
        vm.warp(deadline);

        vm.expectEmit(true, true, true, true);
        emit TimeoutEscrow.EscrowClaimed(id, buyer, seller, AMOUNT);
        vm.prank(seller);
        escrow.claim(id);

        assertEq(token.balanceOf(seller), AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(uint256(escrow.getEscrow(id).status), uint256(TimeoutEscrow.Status.Claimed));
    }

    function test_sellerClaimsLongAfterTheDeadline() public {
        uint256 id = _open();
        vm.warp(deadline + 365 days);

        vm.prank(seller);
        escrow.claim(id);

        assertEq(token.balanceOf(seller), AMOUNT);
    }

    function test_revertWhen_claimingOneSecondEarly() public {
        uint256 id = _open();
        vm.warp(deadline - 1);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.DeadlineNotReached.selector, id, deadline));
        escrow.claim(id);
    }

    function test_revertWhen_buyerTriesToClaim() public {
        uint256 id = _open();
        vm.warp(deadline);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.NotSeller.selector, id, buyer));
        escrow.claim(id);
    }

    function test_revertWhen_strangerTriesToClaim() public {
        uint256 id = _open();
        vm.warp(deadline);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.NotSeller.selector, id, stranger));
        escrow.claim(id);
    }

    function test_revertWhen_claimingAfterADispute() public {
        uint256 id = _open();
        vm.prank(buyer);
        escrow.dispute(id);

        vm.warp(deadline);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.EscrowNotOpen.selector, id));
        escrow.claim(id);
    }

    function test_revertWhen_claimingTwice() public {
        uint256 id = _open();
        vm.warp(deadline);

        vm.startPrank(seller);
        escrow.claim(id);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.EscrowNotOpen.selector, id));
        escrow.claim(id);
        vm.stopPrank();

        assertEq(token.balanceOf(seller), AMOUNT);
    }

    /* ------------------------------------------------------------------ isolation */

    function test_escrowsAreIndependent() public {
        uint256 first = _open();
        uint256 second = _open();
        uint256 third = _open();

        vm.prank(buyer);
        escrow.release(first);
        vm.prank(buyer);
        escrow.dispute(second);

        assertEq(uint256(escrow.getEscrow(third).status), uint256(TimeoutEscrow.Status.Open));
        assertEq(token.balanceOf(address(escrow)), AMOUNT, "only the untouched escrow is still funded");

        vm.warp(deadline);
        vm.prank(seller);
        escrow.claim(third);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(seller), AMOUNT + AMOUNT / 2 + AMOUNT);
    }

    function test_aStrayDonationIsNeverPaidOutOrWithdrawable() public {
        uint256 id = _open();
        token.transfer(address(escrow), 500e18);

        vm.prank(buyer);
        escrow.release(id);

        assertEq(token.balanceOf(seller), AMOUNT, "payout follows the record, not the balance");
        assertEq(token.balanceOf(address(escrow)), 500e18, "the donation stays stuck, by design");
    }

    /* ------------------------------------------------------------------ hostile tokens */

    function test_reentrantReleaseDuringPayoutIsRejected() public {
        (ReentrantToken hostile, TimeoutEscrow victim, uint256 id) = _hostileSetup();
        hostile.arm(address(victim), abi.encodeCall(TimeoutEscrow.release, (id)));

        vm.prank(buyer);
        victim.release(id);

        assertEq(hostile.reentryAttempts(), 1);
        assertFalse(hostile.lastReentrySucceeded(), "re-entrant release must fail");
        assertEq(
            bytes4(hostile.lastReentryReturn()),
            TimeoutEscrow.EscrowNotOpen.selector,
            "the escrow was already settled when the token called back"
        );
        assertEq(hostile.balanceOf(seller), AMOUNT, "the seller was paid exactly once");
        assertEq(hostile.balanceOf(address(victim)), 0);
    }

    function test_reentrantClaimDuringPayoutIsRejected() public {
        (ReentrantToken hostile, TimeoutEscrow victim, uint256 id) = _hostileSetup();
        vm.warp(deadline);
        hostile.arm(address(victim), abi.encodeCall(TimeoutEscrow.claim, (id)));

        vm.prank(seller);
        victim.claim(id);

        assertFalse(hostile.lastReentrySucceeded());
        assertEq(hostile.balanceOf(seller), AMOUNT);
        assertEq(hostile.balanceOf(address(victim)), 0);
    }

    function test_reentrantDisputeDuringTheFirstHalfOfASplitIsRejected() public {
        (ReentrantToken hostile, TimeoutEscrow victim, uint256 id) = _hostileSetup();
        hostile.arm(address(victim), abi.encodeCall(TimeoutEscrow.dispute, (id)));

        vm.prank(buyer);
        victim.dispute(id);

        assertFalse(hostile.lastReentrySucceeded());
        assertEq(hostile.balanceOf(seller), AMOUNT / 2, "the split happened once");
        assertEq(hostile.balanceOf(address(victim)), 0);
    }

    function test_reentrantSettlementOfAnotherEscrowCannotDrainThisOne() public {
        (ReentrantToken hostile, TimeoutEscrow victim, uint256 funded) = _hostileSetup();
        // While the second escrow is being funded the token settles the first one. The second
        // escrow is not recorded yet, so only the first escrow's own tokens can move.
        hostile.arm(address(victim), abi.encodeCall(TimeoutEscrow.release, (funded)));

        vm.prank(buyer);
        uint256 second = victim.open(seller, AMOUNT, deadline);

        assertEq(hostile.lastReentrySucceeded(), false, "the token is not the buyer");
        assertEq(bytes4(hostile.lastReentryReturn()), TimeoutEscrow.NotBuyer.selector);
        assertEq(uint256(victim.getEscrow(second).status), uint256(TimeoutEscrow.Status.Open));
        assertEq(hostile.balanceOf(address(victim)), 2 * AMOUNT, "both escrows are still funded");
    }

    function test_theEscrowIsNotRecordedUntilTheTransferSucceeded() public {
        ReentrantToken hostile = new ReentrantToken();
        TimeoutEscrow victim = new TimeoutEscrow(address(hostile));
        hostile.mint(buyer, 10 * AMOUNT);
        vm.prank(buyer);
        hostile.approve(address(victim), type(uint256).max);

        hostile.arm(address(victim), abi.encodeWithSignature("escrowCount()"));

        vm.prank(buyer);
        victim.open(seller, AMOUNT, deadline);

        assertTrue(hostile.lastReentrySucceeded());
        assertEq(abi.decode(hostile.lastReentryReturn(), (uint256)), 0, "no escrow existed during the pull");
        assertEq(victim.escrowCount(), 1);
    }

    function test_revertWhen_theTokenReturnsFalse() public {
        FalseReturningToken silent = new FalseReturningToken();
        TimeoutEscrow victim = new TimeoutEscrow(address(silent));
        silent.mint(buyer, AMOUNT);

        vm.prank(buyer);
        vm.expectRevert(TimeoutEscrow.TokenTransferFailed.selector);
        victim.open(seller, AMOUNT, deadline);
    }

    function test_revertWhen_theTokenReverts() public {
        RevertingToken broken = new RevertingToken();
        TimeoutEscrow victim = new TimeoutEscrow(address(broken));

        vm.prank(buyer);
        vm.expectRevert(TimeoutEscrow.TokenTransferFailed.selector);
        victim.open(seller, AMOUNT, deadline);
    }

    function test_aTokenWithNoReturnValueIsAccepted() public {
        NoReturnToken quiet = new NoReturnToken();
        TimeoutEscrow victim = new TimeoutEscrow(address(quiet));
        quiet.mint(buyer, AMOUNT);
        vm.prank(buyer);
        quiet.approve(address(victim), AMOUNT);

        vm.prank(buyer);
        uint256 id = victim.open(seller, AMOUNT, deadline);
        vm.prank(buyer);
        victim.release(id);

        assertEq(quiet.balanceOf(seller), AMOUNT);
    }

    function test_revertWhen_theTokenAddressHasNoCode() public {
        // A contract deployed against an EOA: every call "succeeds" with empty return data.
        TimeoutEscrow victim = new TimeoutEscrow(stranger);

        vm.prank(buyer);
        vm.expectRevert(TimeoutEscrow.TokenTransferFailed.selector);
        victim.open(seller, AMOUNT, deadline);
    }

    function _hostileSetup() internal returns (ReentrantToken hostile, TimeoutEscrow victim, uint256 id) {
        hostile = new ReentrantToken();
        victim = new TimeoutEscrow(address(hostile));
        hostile.mint(buyer, 10 * AMOUNT);
        vm.prank(buyer);
        hostile.approve(address(victim), type(uint256).max);
        vm.prank(buyer);
        id = victim.open(seller, AMOUNT, deadline);
    }

    /* ------------------------------------------------------------------ views */

    function test_unknownEscrowReadsBackEmpty() public view {
        TimeoutEscrow.Escrow memory e = escrow.getEscrow(7);
        assertEq(uint256(e.status), uint256(TimeoutEscrow.Status.None));
        assertEq(e.buyer, address(0));
        assertEq(e.amount, 0);
    }

    function test_pagedViewReturnsTheRequestedSlice() public {
        _open();
        _open();
        _open();

        TimeoutEscrow.Escrow[] memory page = escrow.getEscrows(1, 2);
        assertEq(page.length, 2);
        assertEq(page[0].buyer, buyer);
        assertEq(page[1].seller, seller);

        assertEq(escrow.getEscrows(0, 0).length, 0);
        assertEq(escrow.getEscrows(0, 3).length, 3);
    }

    function test_revertWhen_pagingPastTheEnd() public {
        _open();
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.InvalidRange.selector, 0, 2));
        escrow.getEscrows(0, 2);
        vm.expectRevert(abi.encodeWithSelector(TimeoutEscrow.InvalidRange.selector, 1, 1));
        escrow.getEscrows(1, 1);
    }

    /* ------------------------------------------------------------------ properties */

    /// @dev Whichever path an escrow takes, the two parties end up holding exactly what they started
    ///      with, and the contract keeps nothing.
    function testFuzz_settlementConservesEveryToken(uint256 amount, uint64 duration, uint8 path) public {
        amount = bound(amount, 1, 10_000e18);
        uint64 until = uint64(bound(duration, 1, 3650 days)) + uint64(block.timestamp);
        uint256 buyerStart = token.balanceOf(buyer);
        uint256 sellerStart = token.balanceOf(seller);

        vm.prank(buyer);
        uint256 id = escrow.open(seller, amount, until);
        assertEq(token.balanceOf(address(escrow)), amount);

        if (path % 3 == 0) {
            vm.prank(buyer);
            escrow.release(id);
            assertEq(token.balanceOf(seller), sellerStart + amount);
        } else if (path % 3 == 1) {
            vm.prank(buyer);
            escrow.dispute(id);
            assertEq(token.balanceOf(seller), sellerStart + amount - amount / 2);
        } else {
            vm.warp(until);
            vm.prank(seller);
            escrow.claim(id);
            assertEq(token.balanceOf(seller), sellerStart + amount);
        }

        assertEq(token.balanceOf(address(escrow)), 0, "nothing is left behind");
        assertEq(
            token.balanceOf(buyer) + token.balanceOf(seller), buyerStart + sellerStart, "no token was created or lost"
        );
    }

    /// @dev The contract's balance is always the sum of the escrows still open.
    function testFuzz_heldBalanceMatchesTheOpenEscrows(uint8 count, uint8 settleMask) public {
        uint256 n = bound(count, 1, 8);
        uint256 expected;

        for (uint256 i; i < n; ++i) {
            uint256 amount = (i + 1) * 1e18;
            vm.prank(buyer);
            escrow.open(seller, amount, deadline);
            expected += amount;
        }

        for (uint256 i; i < n; ++i) {
            if ((settleMask >> (i % 8)) & 1 == 0) continue;
            vm.prank(buyer);
            escrow.release(i);
            expected -= (i + 1) * 1e18;
        }

        assertEq(token.balanceOf(address(escrow)), expected);
    }
}
