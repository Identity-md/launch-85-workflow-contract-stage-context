// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../src/IERC20.sol";
import {Lastlight} from "../src/Lastlight.sol";
import {Tontine} from "../src/Tontine.sol";
import {ReentrantToken, FalseReturningToken} from "./mocks/MaliciousToken.sol";

contract TontineTest is Test {
    uint256 internal constant OPEN_PERIOD = 30 days;
    uint256 internal constant PING_INTERVAL = 30 days;
    uint256 internal constant STAKE = 100e18;
    uint256 internal constant START = 1_800_000_000;

    Lastlight internal token;
    Tontine internal tontine;

    address internal factory = makeAddr("factory");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(START);
        // Mirror the factory: it deploys the token, then the application with $token, in one flow.
        vm.startPrank(factory);
        token = new Lastlight();
        tontine = new Tontine(token);
        token.transfer(alice, 1_000e18);
        token.transfer(bob, 1_000e18);
        token.transfer(carol, 1_000e18);
        vm.stopPrank();
    }

    // ----------------------------------------------------------- helpers

    function _join(address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(tontine), amount);
        tontine.join(amount);
        vm.stopPrank();
    }

    function _assertConserved() internal view {
        assertEq(token.balanceOf(address(tontine)), tontine.pot(), "pot must equal held balance");
        if (tontine.pot() > 0) {
            assertGt(tontine.participantCount(), 0, "a funded pot must always have a claimant");
        }
    }

    function _assertRosterConsistent() internal view {
        address[] memory roster = tontine.participants();
        assertEq(roster.length, tontine.participantCount());
        for (uint256 i; i < roster.length; ++i) {
            assertTrue(tontine.isParticipant(roster[i]));
            for (uint256 j = i + 1; j < roster.length; ++j) {
                assertTrue(roster[i] != roster[j], "duplicate roster entry");
            }
        }
    }

    // ------------------------------------------------------- construction

    function test_constructor() public view {
        assertEq(address(tontine.token()), address(token));
        assertEq(tontine.openUntil(), START + OPEN_PERIOD);
        assertEq(tontine.OPEN_PERIOD(), OPEN_PERIOD);
        assertEq(tontine.PING_INTERVAL(), PING_INTERVAL);
        assertTrue(tontine.isOpen());
        assertEq(tontine.pot(), 0);
        assertEq(tontine.winner(), address(0));
        assertEq(tontine.participantCount(), 0);
        assertEq(tontine.participants().length, 0);
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(Tontine.ZeroToken.selector);
        new Tontine(IERC20(address(0)));
    }

    function test_constructorHoldsNoTokensAndHasNoPrivilege() public view {
        // The factory's supply must be untouched by application construction.
        assertEq(token.balanceOf(address(tontine)), 0);
        assertEq(token.balanceOf(factory), token.totalSupply() - 3_000e18);
    }

    // --------------------------------------------------------------- join

    function test_join() public {
        vm.startPrank(alice);
        token.approve(address(tontine), STAKE);
        vm.expectEmit(true, true, true, true);
        emit Tontine.Joined(alice, STAKE, STAKE);
        tontine.join(STAKE);
        vm.stopPrank();

        assertTrue(tontine.isParticipant(alice));
        assertEq(tontine.depositOf(alice), STAKE);
        assertEq(tontine.lastPingOf(alice), START);
        assertEq(tontine.deadlineOf(alice), START + PING_INTERVAL);
        assertEq(tontine.pot(), STAKE);
        assertEq(tontine.participantCount(), 1);
        assertEq(tontine.participants()[0], alice);
        assertEq(token.balanceOf(alice), 1_000e18 - STAKE);
        _assertConserved();
    }

    function test_joinAccumulatesPotAcrossParticipants() public {
        _join(alice, 10e18);
        _join(bob, 20e18);
        _join(carol, 30e18);
        assertEq(tontine.pot(), 60e18);
        assertEq(tontine.participantCount(), 3);
        _assertConserved();
        _assertRosterConsistent();
    }

    function test_joinRevertsOnZeroAmount() public {
        vm.expectRevert(Tontine.ZeroAmount.selector);
        vm.prank(alice);
        tontine.join(0);
    }

    function test_joinRevertsWithoutApproval() public {
        vm.expectRevert(abi.encodeWithSelector(Lastlight.InsufficientAllowance.selector, 0, STAKE));
        vm.prank(alice);
        tontine.join(STAKE);
        assertFalse(tontine.isParticipant(alice));
        assertEq(tontine.pot(), 0);
    }

    function test_joinRevertsWhenBalanceTooLow() public {
        vm.startPrank(stranger);
        token.approve(address(tontine), STAKE);
        vm.expectRevert(abi.encodeWithSelector(Lastlight.InsufficientBalance.selector, 0, STAKE));
        tontine.join(STAKE);
        vm.stopPrank();
        assertEq(tontine.participantCount(), 0);
    }

    function test_joinRevertsWhenAlreadyJoined() public {
        _join(alice, STAKE);
        vm.startPrank(alice);
        token.approve(address(tontine), STAKE);
        vm.expectRevert(Tontine.AlreadyJoined.selector);
        tontine.join(STAKE);
        vm.stopPrank();
        assertEq(tontine.depositOf(alice), STAKE);
        assertEq(tontine.pot(), STAKE);
    }

    function test_joinAllowedUntilTheLastSecondOfTheOpenPeriod() public {
        vm.warp(START + OPEN_PERIOD - 1);
        assertTrue(tontine.isOpen());
        _join(alice, STAKE);
        assertTrue(tontine.isParticipant(alice));
    }

    function test_joinRevertsOnceTheOpenPeriodEnds() public {
        vm.warp(START + OPEN_PERIOD);
        assertFalse(tontine.isOpen());
        vm.startPrank(alice);
        token.approve(address(tontine), STAKE);
        vm.expectRevert(Tontine.JoiningClosed.selector);
        tontine.join(STAKE);
        vm.stopPrank();
    }

    function test_evictedParticipantCannotRejoin() public {
        // Joining closes before anyone can be overdue, so an eviction always lands after the close.
        _join(alice, STAKE);
        _join(bob, STAKE);
        vm.warp(START + PING_INTERVAL + 1);
        vm.prank(bob);
        tontine.ping();
        tontine.evict(alice);
        assertFalse(tontine.isParticipant(alice));

        vm.startPrank(alice);
        token.approve(address(tontine), 1e18);
        vm.expectRevert(Tontine.JoiningClosed.selector);
        tontine.join(1e18);
        vm.stopPrank();
        assertEq(tontine.pot(), 2 * STAKE, "the forfeited stake stays in the pot");
        _assertConserved();
    }

    // --------------------------------------------------------------- ping

    function test_ping() public {
        _join(alice, STAKE);
        vm.warp(START + 10 days);
        vm.expectEmit(true, true, true, true);
        emit Tontine.Pinged(alice, START + 10 days);
        vm.prank(alice);
        tontine.ping();
        assertEq(tontine.lastPingOf(alice), START + 10 days);
        assertEq(tontine.deadlineOf(alice), START + 10 days + PING_INTERVAL);
    }

    function test_pingRevertsForNonParticipant() public {
        vm.expectRevert(Tontine.NotParticipant.selector);
        vm.prank(stranger);
        tontine.ping();
    }

    function test_pingRevertsAfterEviction() public {
        _join(alice, STAKE);
        _join(bob, STAKE);
        vm.warp(START + PING_INTERVAL + 1);
        vm.prank(bob);
        tontine.ping();
        tontine.evict(alice);
        vm.expectRevert(Tontine.NotParticipant.selector);
        vm.prank(alice);
        tontine.ping();
    }

    function test_pingRevertsAfterClaim() public {
        _join(alice, STAKE);
        vm.warp(START + OPEN_PERIOD);
        vm.prank(alice);
        tontine.claim();
        vm.expectRevert(Tontine.NotParticipant.selector);
        vm.prank(alice);
        tontine.ping();
    }

    function test_overdueParticipantCanStillPingBeforeEviction() public {
        _join(alice, STAKE);
        _join(bob, STAKE);
        vm.warp(START + PING_INTERVAL + 5 days);
        assertTrue(tontine.canEvict(alice));
        vm.prank(alice);
        tontine.ping();
        assertFalse(tontine.canEvict(alice));
        vm.expectRevert(Tontine.NotOverdue.selector);
        tontine.evict(alice);
    }

    function test_pingDoesNotChangeFunds() public {
        _join(alice, STAKE);
        vm.prank(alice);
        tontine.ping();
        assertEq(tontine.pot(), STAKE);
        assertEq(tontine.depositOf(alice), STAKE);
        _assertConserved();
    }

    // -------------------------------------------------------------- evict

    function test_evict() public {
        _join(alice, 10e18);
        _join(bob, 20e18);
        vm.warp(START + PING_INTERVAL + 1);
        vm.prank(bob);
        tontine.ping();

        vm.expectEmit(true, true, true, true);
        emit Tontine.Evicted(alice, stranger, 10e18);
        vm.prank(stranger);
        tontine.evict(alice);

        assertFalse(tontine.isParticipant(alice));
        assertEq(tontine.depositOf(alice), 0);
        assertEq(tontine.lastPingOf(alice), 0);
        assertEq(tontine.deadlineOf(alice), 0);
        assertEq(tontine.pot(), 30e18, "the forfeited deposit stays in the pot");
        assertEq(tontine.participantCount(), 1);
        assertEq(tontine.participants()[0], bob);
        assertEq(token.balanceOf(alice), 1_000e18 - 10e18, "no refund on eviction");
        assertEq(token.balanceOf(stranger), 0, "evictors are not rewarded");
        _assertConserved();
    }

    function test_evictByAnyoneIncludingSelfAndParticipants() public {
        _join(alice, STAKE);
        _join(bob, STAKE);
        _join(carol, STAKE);
        vm.warp(START + PING_INTERVAL + 1);
        vm.prank(carol);
        tontine.ping();

        vm.prank(bob);
        tontine.evict(alice);
        vm.prank(bob);
        tontine.evict(bob);
        assertEq(tontine.participantCount(), 1);
        assertEq(tontine.participants()[0], carol);
    }

    function test_evictAtExactDeadlineReverts() public {
        _join(alice, STAKE);
        _join(bob, STAKE);
        vm.warp(START + PING_INTERVAL);
        assertFalse(tontine.canEvict(alice));
        vm.expectRevert(Tontine.NotOverdue.selector);
        tontine.evict(alice);
    }

    function test_evictOneSecondAfterDeadlineSucceeds() public {
        _join(alice, STAKE);
        _join(bob, STAKE);
        vm.warp(START + PING_INTERVAL + 1);
        assertTrue(tontine.canEvict(alice));
        tontine.evict(alice);
        assertFalse(tontine.isParticipant(alice));
    }

    function test_evictDeadlineFollowsLatestPing() public {
        _join(alice, STAKE);
        _join(bob, STAKE);
        vm.warp(START + 20 days);
        vm.prank(alice);
        tontine.ping();
        vm.warp(START + PING_INTERVAL + 1);
        vm.expectRevert(Tontine.NotOverdue.selector);
        tontine.evict(alice);
        vm.warp(START + 20 days + PING_INTERVAL + 1);
        tontine.evict(alice);
        assertFalse(tontine.isParticipant(alice));
    }

    function test_evictRevertsForNonParticipant() public {
        _join(alice, STAKE);
        vm.warp(START + PING_INTERVAL + 1);
        vm.expectRevert(Tontine.NotParticipant.selector);
        tontine.evict(stranger);
    }

    function test_evictRevertsForTheLastParticipant() public {
        _join(alice, STAKE);
        vm.warp(START + 10 * PING_INTERVAL);
        assertFalse(tontine.canEvict(alice));
        vm.expectRevert(Tontine.CannotEvictLast.selector);
        tontine.evict(alice);
        _assertConserved();
    }

    function test_nobodyIsEvictableWhileJoiningIsOpen() public {
        // OPEN_PERIOD <= PING_INTERVAL: the earliest possible eviction is one second after the
        // earliest possible join plus PING_INTERVAL, which is never before openUntil.
        assertLe(tontine.OPEN_PERIOD(), tontine.PING_INTERVAL());
        _join(alice, STAKE);
        vm.warp(START + 1 days);
        _join(bob, STAKE);
        vm.warp(START + OPEN_PERIOD - 1);
        assertTrue(tontine.isOpen());
        assertFalse(tontine.canEvict(alice));
        assertFalse(tontine.canEvict(bob));
        vm.expectRevert(Tontine.NotOverdue.selector);
        tontine.evict(alice);

        // Two seconds later joining is closed and alice, who joined first, is overdue.
        vm.warp(START + PING_INTERVAL + 1);
        assertFalse(tontine.isOpen());
        tontine.evict(alice);
        assertEq(tontine.participantCount(), 1);
    }

    function test_evictedCannotBeEvictedTwice() public {
        _join(alice, STAKE);
        _join(bob, STAKE);
        _join(carol, STAKE);
        vm.warp(START + PING_INTERVAL + 1);
        tontine.evict(alice);
        vm.expectRevert(Tontine.NotParticipant.selector);
        tontine.evict(alice);
    }

    function test_rosterSwapAndPopKeepsEveryoneElse() public {
        address[8] memory people;
        for (uint256 i; i < people.length; ++i) {
            people[i] = makeAddr(string.concat("p", vm.toString(i)));
            vm.prank(factory);
            token.transfer(people[i], STAKE);
            _join(people[i], STAKE);
        }
        vm.warp(START + PING_INTERVAL + 1);
        for (uint256 i; i < people.length; ++i) {
            if (i == 2 || i == 5 || i == 7) continue;
            vm.prank(people[i]);
            tontine.ping();
        }
        tontine.evict(people[2]);
        tontine.evict(people[7]);
        tontine.evict(people[5]);

        assertEq(tontine.participantCount(), 5);
        _assertRosterConsistent();
        for (uint256 i; i < people.length; ++i) {
            bool expected = !(i == 2 || i == 5 || i == 7);
            assertEq(tontine.isParticipant(people[i]), expected);
            if (expected) assertEq(tontine.depositOf(people[i]), STAKE);
        }
        assertEq(tontine.pot(), 8 * STAKE);
        _assertConserved();
    }

    // -------------------------------------------------------------- claim

    function test_claim() public {
        _join(alice, 10e18);
        _join(bob, 20e18);
        vm.warp(START + PING_INTERVAL + 1);
        vm.prank(bob);
        tontine.ping();
        tontine.evict(alice);

        assertTrue(tontine.canClaim(bob));
        vm.expectEmit(true, true, true, true);
        emit Tontine.Claimed(bob, 30e18);
        vm.prank(bob);
        tontine.claim();

        assertEq(token.balanceOf(bob), 1_000e18 - 20e18 + 30e18);
        assertEq(token.balanceOf(address(tontine)), 0);
        assertEq(tontine.pot(), 0);
        assertEq(tontine.winner(), bob);
        assertEq(tontine.participantCount(), 0);
        assertFalse(tontine.isParticipant(bob));
        assertFalse(tontine.canClaim(bob));
        _assertConserved();
    }

    function test_soleEntrantClaimsOwnDepositBackAfterClose() public {
        _join(alice, STAKE);
        vm.warp(START + OPEN_PERIOD);
        vm.prank(alice);
        tontine.claim();
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(tontine.winner(), alice);
    }

    function test_claimRevertsWhileOpen() public {
        _join(alice, STAKE);
        vm.warp(START + OPEN_PERIOD - 1);
        assertFalse(tontine.canClaim(alice));
        vm.expectRevert(Tontine.StillOpen.selector);
        vm.prank(alice);
        tontine.claim();
    }

    function test_claimSucceedsAtTheExactCloseTimestamp() public {
        _join(alice, STAKE);
        vm.warp(START + OPEN_PERIOD);
        vm.prank(alice);
        tontine.claim();
        assertEq(tontine.winner(), alice);
    }

    function test_claimRevertsWhenOthersRemain() public {
        _join(alice, STAKE);
        _join(bob, STAKE);
        vm.warp(START + OPEN_PERIOD);
        assertFalse(tontine.canClaim(alice));
        vm.expectRevert(Tontine.NotLastStanding.selector);
        vm.prank(alice);
        tontine.claim();
    }

    function test_claimRevertsForNonParticipant() public {
        _join(alice, STAKE);
        vm.warp(START + OPEN_PERIOD);
        vm.expectRevert(Tontine.NotParticipant.selector);
        vm.prank(stranger);
        tontine.claim();
    }

    function test_claimRevertsForEvictedParticipant() public {
        _join(alice, STAKE);
        _join(bob, STAKE);
        vm.warp(START + PING_INTERVAL + 1);
        vm.prank(bob);
        tontine.ping();
        tontine.evict(alice);
        vm.expectRevert(Tontine.NotParticipant.selector);
        vm.prank(alice);
        tontine.claim();
    }

    function test_claimTwiceReverts() public {
        _join(alice, STAKE);
        vm.warp(START + OPEN_PERIOD);
        vm.startPrank(alice);
        tontine.claim();
        vm.expectRevert(Tontine.NotParticipant.selector);
        tontine.claim();
        vm.stopPrank();
    }

    function test_nothingWorksAfterClaim() public {
        _join(alice, STAKE);
        vm.warp(START + OPEN_PERIOD);
        vm.prank(alice);
        tontine.claim();

        vm.startPrank(bob);
        token.approve(address(tontine), STAKE);
        vm.expectRevert(Tontine.JoiningClosed.selector);
        tontine.join(STAKE);
        vm.stopPrank();

        vm.expectRevert(Tontine.NotParticipant.selector);
        tontine.evict(alice);
        assertEq(token.balanceOf(address(tontine)), 0);
    }

    function test_soleSurvivorNeedNotPingToClaimLater() public {
        _join(alice, STAKE);
        _join(bob, STAKE);
        vm.warp(START + PING_INTERVAL + 1);
        vm.prank(bob);
        tontine.ping();
        tontine.evict(alice);
        // Bob goes quiet for a year; nobody can evict the last participant.
        vm.warp(START + 365 days);
        assertFalse(tontine.canEvict(bob));
        vm.prank(bob);
        tontine.claim();
        assertEq(tontine.winner(), bob);
    }

    // ----------------------------------------------------- full lifecycle

    function test_lifecycleWinnerReceivesEveryDeposit() public {
        _join(alice, 10e18);
        vm.warp(START + 5 days);
        _join(bob, 20e18);
        vm.warp(START + 10 days);
        _join(carol, 30e18);
        _assertConserved();

        // Everyone pings once, then alice stops.
        vm.warp(START + 20 days);
        vm.prank(alice);
        tontine.ping();
        vm.prank(bob);
        tontine.ping();
        vm.prank(carol);
        tontine.ping();

        vm.warp(START + 20 days + PING_INTERVAL + 1);
        vm.expectRevert(Tontine.NotLastStanding.selector);
        vm.prank(bob);
        tontine.claim();

        vm.prank(bob);
        tontine.ping();
        vm.prank(carol);
        tontine.ping();
        tontine.evict(alice);
        _assertConserved();

        // Carol stops next.
        vm.warp(START + 20 days + 2 * PING_INTERVAL + 2);
        vm.prank(bob);
        tontine.ping();
        vm.prank(stranger);
        tontine.evict(carol);
        _assertConserved();

        vm.prank(bob);
        tontine.claim();
        assertEq(token.balanceOf(bob), 1_000e18 - 20e18 + 60e18);
        assertEq(token.balanceOf(address(tontine)), 0);
        assertEq(tontine.pot(), 0);
        assertEq(tontine.winner(), bob);
    }

    function testFuzz_conservationAcrossJoinsEvictionsAndClaim(uint256 seed, uint8 rawCount) public {
        uint256 count = bound(rawCount, 1, 12);
        address[] memory people = new address[](count);
        uint256 total;
        for (uint256 i; i < count; ++i) {
            people[i] = makeAddr(string.concat("fuzz", vm.toString(i)));
            uint256 amount = (uint256(keccak256(abi.encode(seed, i))) % 1_000e18) + 1;
            vm.prank(factory);
            token.transfer(people[i], amount);
            _join(people[i], amount);
            total += amount;
            _assertConserved();
        }
        assertEq(tontine.pot(), total);

        // The survivor is chosen by the seed; everyone else goes quiet and gets evicted.
        uint256 survivor = uint256(keccak256(abi.encode(seed, "survivor"))) % count;
        vm.warp(START + PING_INTERVAL + 1);
        vm.prank(people[survivor]);
        tontine.ping();
        for (uint256 i; i < count; ++i) {
            if (i == survivor) continue;
            tontine.evict(people[i]);
            _assertConserved();
            _assertRosterConsistent();
        }
        assertEq(tontine.participantCount(), 1);
        assertEq(tontine.pot(), total);

        uint256 before = token.balanceOf(people[survivor]);
        vm.prank(people[survivor]);
        tontine.claim();
        assertEq(token.balanceOf(people[survivor]), before + total);
        assertEq(token.balanceOf(address(tontine)), 0);
        _assertConserved();
    }

    // ---------------------------------------------------------- reentrancy

    function _deployWithReentrantToken() internal returns (ReentrantToken bad, Tontine t) {
        bad = new ReentrantToken();
        t = new Tontine(bad);
        bad.mint(alice, 1_000e18);
        bad.mint(bob, 1_000e18);
        vm.prank(alice);
        bad.approve(address(t), type(uint256).max);
        vm.prank(bob);
        bad.approve(address(t), type(uint256).max);
    }

    function test_reentrantClaimDuringPayoutIsRejected() public {
        (ReentrantToken bad, Tontine t) = _deployWithReentrantToken();
        vm.prank(alice);
        t.join(STAKE);
        vm.warp(START + OPEN_PERIOD);

        bad.arm(t, ReentrantToken.Attack.Claim, address(0));
        vm.prank(alice);
        t.claim();

        assertEq(bad.attempts(), 1, "the token did re-enter");
        assertEq(bad.innerReverts(), 1, "the nested claim reverted");
        assertEq(bad.balanceOf(alice), 1_000e18, "paid exactly once");
        assertEq(bad.balanceOf(address(t)), 0);
        assertEq(t.pot(), 0);
        assertEq(t.winner(), alice);
    }

    function test_reentrantPingDuringJoinIsRejected() public {
        (ReentrantToken bad, Tontine t) = _deployWithReentrantToken();
        bad.arm(t, ReentrantToken.Attack.Ping, address(0));
        vm.prank(alice);
        t.join(STAKE);
        assertEq(bad.attempts(), 1);
        assertEq(bad.innerReverts(), 1, "the token is not a participant, so its ping reverts");
        assertEq(t.participantCount(), 1);
        assertEq(t.pot(), STAKE);
        assertEq(bad.balanceOf(address(t)), STAKE);
    }

    function test_reentrantClaimDuringJoinIsRejected() public {
        (ReentrantToken bad, Tontine t) = _deployWithReentrantToken();
        bad.arm(t, ReentrantToken.Attack.Claim, address(0));
        vm.prank(alice);
        t.join(STAKE);
        assertEq(bad.innerReverts(), 1);
        assertEq(t.pot(), STAKE);
        assertEq(t.winner(), address(0));
    }

    function test_reentrantEvictDuringJoinCannotTouchFreshEntrant() public {
        (ReentrantToken bad, Tontine t) = _deployWithReentrantToken();
        vm.prank(bob);
        t.join(STAKE);
        // Alice joins with her clock freshly set, so an eviction from inside her deposit must fail.
        bad.arm(t, ReentrantToken.Attack.Evict, alice);
        vm.prank(alice);
        t.join(STAKE);
        assertEq(bad.attempts(), 1);
        assertEq(bad.innerReverts(), 1);
        assertTrue(t.isParticipant(alice));
        assertEq(t.participantCount(), 2);
        assertEq(t.pot(), 2 * STAKE);
    }

    function test_reentrantJoinByTheTokenIsJustAnotherEntry() public {
        // A token that joins from inside transferFrom becomes a regular participant under its own
        // address; it gains nothing beyond what any entrant gets, and accounting stays exact.
        (ReentrantToken bad, Tontine t) = _deployWithReentrantToken();
        bad.arm(t, ReentrantToken.Attack.Join, address(0));
        vm.prank(alice);
        t.join(STAKE);
        assertEq(bad.attempts(), 1);
        assertEq(bad.innerReverts(), 0);
        assertEq(t.participantCount(), 2);
        assertTrue(t.isParticipant(address(bad)));
        assertEq(t.depositOf(address(bad)), 1);
        assertEq(t.depositOf(alice), STAKE);
        assertEq(t.pot(), STAKE + 1);
        assertEq(bad.balanceOf(address(t)), STAKE + 1);
    }

    // --------------------------------------------------- settlement failure

    function test_joinRevertsWhenTokenReportsFailure() public {
        FalseReturningToken bad = new FalseReturningToken();
        Tontine t = new Tontine(bad);
        bad.mint(alice, STAKE);
        bad.setFailures(false, true);
        vm.startPrank(alice);
        bad.approve(address(t), STAKE);
        vm.expectRevert(Tontine.TransferFailed.selector);
        t.join(STAKE);
        vm.stopPrank();
        assertEq(t.participantCount(), 0);
        assertEq(t.pot(), 0);
    }

    function test_claimRevertsAndKeepsStateWhenPayoutFails() public {
        FalseReturningToken bad = new FalseReturningToken();
        Tontine t = new Tontine(bad);
        bad.mint(alice, STAKE);
        vm.startPrank(alice);
        bad.approve(address(t), STAKE);
        t.join(STAKE);
        vm.stopPrank();

        vm.warp(START + OPEN_PERIOD);
        bad.setFailures(true, false);
        vm.expectRevert(Tontine.TransferFailed.selector);
        vm.prank(alice);
        t.claim();

        // Nothing was lost: the claim can be retried once the token behaves.
        assertTrue(t.isParticipant(alice));
        assertEq(t.pot(), STAKE);
        assertEq(t.winner(), address(0));
        bad.setFailures(false, false);
        vm.prank(alice);
        t.claim();
        assertEq(bad.balanceOf(alice), STAKE);
        assertEq(t.winner(), alice);
    }

    // ---------------------------------------------------------- no escape

    function test_hasNoAdminSurface() public {
        string[8] memory signatures = [
            "owner()",
            "withdraw(uint256)",
            "withdraw(address,uint256)",
            "setOpenUntil(uint256)",
            "pause()",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "rescue(address)"
        ];
        _join(alice, STAKE);
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], factory, uint256(1));
            vm.prank(factory);
            (bool ok,) = address(tontine).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(tontine.pot(), STAKE);
        _assertConserved();
    }

    function test_contractRejectsPlainEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(tontine).call{value: 1 ether}("");
        assertFalse(ok, "no receive/fallback: ETH cannot get stuck here");
    }
}
