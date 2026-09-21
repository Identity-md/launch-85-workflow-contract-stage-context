// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./IERC20.sol";

/// @title Tontine
/// @notice A survival game over LAST deposits.
///
/// Rules:
///  - Anyone may join once by depositing any positive amount of LAST while the contract is open. The
///    open period is `OPEN_PERIOD` from deployment; joining is allowed strictly before `openUntil`.
///  - Every participant must `ping` at least once every `PING_INTERVAL` (30 days). A ping made exactly
///    at the deadline still counts.
///  - A participant who has missed a ping may be evicted by anyone. An evicted participant forfeits
///    their deposit to the pot and, because joining has closed by then (`OPEN_PERIOD` is not longer
///    than `PING_INTERVAL`), cannot come back.
///  - The last participant standing is never evicted, so the pot is always claimable by someone.
///  - Once the open period is over and exactly one participant remains, that participant claims the
///    whole pot. After the claim the contract is finished: nothing else can happen.
///
/// There is no owner, no fee, no admin, no withdrawal and no upgrade path. The only external calls
/// are `transferFrom` on join and `transfer` on claim, both made after all state changes.
contract Tontine {
    /// @notice How long joining stays open after deployment.
    uint256 public constant OPEN_PERIOD = 30 days;
    /// @notice The maximum time a participant may go without pinging before becoming evictable.
    uint256 public constant PING_INTERVAL = 30 days;

    /// @notice The token deposited and paid out.
    IERC20 public immutable token;
    /// @notice Joining is allowed while `block.timestamp < openUntil`.
    uint256 public immutable openUntil;

    /// @notice Total LAST held for the eventual winner: every deposit ever made, minus the payout.
    uint256 public pot;
    /// @notice The participant who claimed the pot, or the zero address while the game is running.
    address public winner;

    /// @notice Amount a current participant deposited when they joined.
    mapping(address participant => uint256) public depositOf;
    /// @notice Timestamp of a current participant's latest ping (or join).
    mapping(address participant => uint256) public lastPingOf;
    /// @dev 1-based position in `_roster`; 0 means not a participant.
    mapping(address participant => uint256) private _slotOf;
    address[] private _roster;

    event Joined(address indexed participant, uint256 amount, uint256 pot);
    event Pinged(address indexed participant, uint256 timestamp);
    event Evicted(address indexed participant, address indexed by, uint256 forfeited);
    event Claimed(address indexed winner, uint256 amount);

    error ZeroToken();
    error ZeroAmount();
    error JoiningClosed();
    error AlreadyJoined();
    error NotParticipant();
    error NotOverdue();
    error CannotEvictLast();
    error StillOpen();
    error NotLastStanding();
    error TransferFailed();

    /// @param token_ The LAST token. Under ProjectFactory this is the `$token` reference.
    constructor(IERC20 token_) {
        if (address(token_) == address(0)) revert ZeroToken();
        token = token_;
        openUntil = block.timestamp + OPEN_PERIOD;
    }

    // ---------------------------------------------------------------- actions

    /// @notice Deposit `amount` LAST and enter the game. Requires a prior approval.
    function join(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp >= openUntil) revert JoiningClosed();
        if (_slotOf[msg.sender] != 0) revert AlreadyJoined();

        _roster.push(msg.sender);
        _slotOf[msg.sender] = _roster.length;
        depositOf[msg.sender] = amount;
        lastPingOf[msg.sender] = block.timestamp;
        pot += amount;
        emit Joined(msg.sender, amount, pot);

        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
    }

    /// @notice Prove you are still here. Resets the 30-day clock, even if it had already run out.
    function ping() external {
        if (_slotOf[msg.sender] == 0) revert NotParticipant();
        lastPingOf[msg.sender] = block.timestamp;
        emit Pinged(msg.sender, block.timestamp);
    }

    /// @notice Remove a participant who has not pinged for more than `PING_INTERVAL`.
    /// @dev Anyone may call this. The last remaining participant cannot be evicted.
    function evict(address participant) external {
        if (_slotOf[participant] == 0) revert NotParticipant();
        if (!_isOverdue(participant)) revert NotOverdue();
        if (_roster.length == 1) revert CannotEvictLast();

        uint256 forfeited = depositOf[participant];
        _remove(participant);
        emit Evicted(participant, msg.sender, forfeited);
    }

    /// @notice Take the whole pot as the sole remaining participant after the open period.
    function claim() external {
        if (_slotOf[msg.sender] == 0) revert NotParticipant();
        if (block.timestamp < openUntil) revert StillOpen();
        if (_roster.length != 1) revert NotLastStanding();

        uint256 amount = pot;
        pot = 0;
        winner = msg.sender;
        _remove(msg.sender);
        emit Claimed(msg.sender, amount);

        if (!token.transfer(msg.sender, amount)) revert TransferFailed();
    }

    // ------------------------------------------------------------------ views

    /// @notice Whether joining is currently allowed.
    function isOpen() external view returns (bool) {
        return block.timestamp < openUntil;
    }

    /// @notice Whether `account` is currently in the game.
    function isParticipant(address account) external view returns (bool) {
        return _slotOf[account] != 0;
    }

    /// @notice Number of participants still in the game.
    function participantCount() external view returns (uint256) {
        return _roster.length;
    }

    /// @notice Every participant still in the game, in no particular order.
    function participants() external view returns (address[] memory) {
        return _roster;
    }

    /// @notice The last moment `participant` may ping before becoming evictable.
    function deadlineOf(address participant) external view returns (uint256) {
        if (_slotOf[participant] == 0) return 0;
        return lastPingOf[participant] + PING_INTERVAL;
    }

    /// @notice Whether `evict(participant)` would currently succeed.
    function canEvict(address participant) external view returns (bool) {
        return _slotOf[participant] != 0 && _isOverdue(participant) && _roster.length > 1;
    }

    /// @notice Whether `account` could call `claim()` right now.
    function canClaim(address account) external view returns (bool) {
        return _slotOf[account] != 0 && block.timestamp >= openUntil && _roster.length == 1;
    }

    // -------------------------------------------------------------- internals

    function _isOverdue(address participant) private view returns (bool) {
        return block.timestamp > lastPingOf[participant] + PING_INTERVAL;
    }

    /// @dev Swap-and-pop removal from the roster; clears all per-participant state.
    function _remove(address participant) private {
        uint256 slot = _slotOf[participant];
        uint256 lastSlot = _roster.length;
        if (slot != lastSlot) {
            address moved = _roster[lastSlot - 1];
            _roster[slot - 1] = moved;
            _slotOf[moved] = slot;
        }
        _roster.pop();
        delete _slotOf[participant];
        delete depositOf[participant];
        delete lastPingOf[participant];
    }
}
