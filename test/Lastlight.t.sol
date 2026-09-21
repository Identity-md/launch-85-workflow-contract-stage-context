// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../src/IERC20.sol";
import {Lastlight} from "../src/Lastlight.sol";

contract LastlightTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    Lastlight internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.prank(deployer);
        token = new Lastlight();
    }

    // ------------------------------------------------------------ metadata

    function test_metadata() public view {
        assertEq(token.name(), "Lastlight");
        assertEq(token.symbol(), "LAST");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsFixedAtOneBillionTokens() public view {
        assertEq(SUPPLY, 10 ** 27, "policy supply is 10^27 minor units");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        Lastlight fresh = new Lastlight();
        assertEq(fresh.balanceOf(alice), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_noMintOrAdminEntryPoints() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, uint256(1));
            vm.prank(deployer);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    // ------------------------------------------------------------ transfer

    function test_transfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, 1e18);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1e18));
        assertEq(token.balanceOf(alice), 1e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 1e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferZeroAmountIsAllowed() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        token.transfer(deployer, 5e18);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(Lastlight.InsufficientBalance.selector, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(Lastlight.InvalidReceiver.selector);
        vm.prank(deployer);
        token.transfer(address(0), 1);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + (to == deployer ? 0 : token.balanceOf(deployer)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------ allowance

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, alice, 7);
        vm.prank(deployer);
        assertTrue(token.approve(alice, 7));
        assertEq(token.allowance(deployer, alice), 7);
    }

    function test_approveOverwritesRatherThanAdds() public {
        vm.startPrank(deployer);
        token.approve(alice, 7);
        token.approve(alice, 3);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 3);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.expectRevert(Lastlight.InvalidSpender.selector);
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, bob, 4);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 4));

        assertEq(token.balanceOf(bob), 4);
        assertEq(token.balanceOf(deployer), SUPPLY - 4);
        assertEq(token.allowance(deployer, alice), 6);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 3);
        vm.expectRevert(abi.encodeWithSelector(Lastlight.InsufficientAllowance.selector, 3, 4));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 4);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(Lastlight.InsufficientAllowance.selector, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromRevertsWhenOwnerLacksBalance() public {
        vm.prank(alice);
        token.approve(bob, 100);
        vm.expectRevert(abi.encodeWithSelector(Lastlight.InsufficientBalance.selector, 0, 100));
        vm.prank(bob);
        token.transferFrom(alice, bob, 100);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
        assertEq(token.balanceOf(bob), 1e18);
    }

    function test_selfTransferFromStillNeedsAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(Lastlight.InsufficientAllowance.selector, 0, 1));
        vm.prank(deployer);
        token.transferFrom(deployer, alice, 1);
    }
}
