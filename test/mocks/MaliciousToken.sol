// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../../src/IERC20.sol";
import {Tontine} from "../../src/Tontine.sol";

/// @notice A token that re-enters the Tontine from inside `transfer` / `transferFrom`.
/// @dev Balances are tracked honestly so the test can still check conservation. Every re-entrant
/// attempt is recorded so the test can assert that the inner calls reverted while the outer call
/// completed exactly once.
contract ReentrantToken is IERC20 {
    enum Attack {
        None,
        Join,
        Ping,
        Evict,
        Claim
    }

    string public constant name = "Reentrant";
    string public constant symbol = "REENT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    Tontine public tontine;
    Attack public attack;
    address public victim;
    uint256 public attempts;
    uint256 public innerReverts;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function arm(Tontine tontine_, Attack attack_, address victim_) external {
        tontine = tontine_;
        attack = attack_;
        victim = victim_;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        _reenter();
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 current = allowance[from][msg.sender];
        require(current >= value, "allowance");
        allowance[from][msg.sender] = current - value;
        _move(from, to, value);
        _reenter();
        return true;
    }

    function _move(address from, address to, uint256 value) private {
        require(balanceOf[from] >= value, "balance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    function _reenter() private {
        Attack a = attack;
        if (a == Attack.None) return;
        // Disarm before the call so a successful re-entry cannot recurse forever.
        attack = Attack.None;
        attempts += 1;
        bool ok;
        if (a == Attack.Join) {
            balanceOf[address(this)] += 1;
            totalSupply += 1;
            allowance[address(this)][address(tontine)] = 1;
            ok = _try(abi.encodeCall(Tontine.join, (1)));
        } else if (a == Attack.Ping) {
            ok = _try(abi.encodeCall(Tontine.ping, ()));
        } else if (a == Attack.Evict) {
            ok = _try(abi.encodeCall(Tontine.evict, (victim)));
        } else {
            ok = _try(abi.encodeCall(Tontine.claim, ()));
        }
        if (!ok) innerReverts += 1;
    }

    function _try(bytes memory data) private returns (bool ok) {
        (ok,) = address(tontine).call(data);
    }
}

/// @notice A token whose transfers report failure instead of reverting.
contract FalseReturningToken is IERC20 {
    string public constant name = "False";
    string public constant symbol = "FALSE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public failTransfers;
    bool public failTransferFroms;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setFailures(bool transfers, bool transferFroms) external {
        failTransfers = transfers;
        failTransferFroms = transferFroms;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        if (failTransfers) return false;
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (failTransferFroms) return false;
        allowance[from][msg.sender] -= value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }
}
