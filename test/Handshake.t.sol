// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Handshake} from "../src/Handshake.sol";
import {IERC20} from "../src/IERC20.sol";

contract HandshakeTest is Test {
    Handshake internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new Handshake();
    }

    /* ------------------------------------------------------------------ launch shape */

    function test_metadataIsFixed() public view {
        assertEq(token.name(), "Handshake");
        assertEq(token.symbol(), "SHAKE");
        assertEq(token.decimals(), 18);
    }

    function test_mintsTheWholeSupplyToTheDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.INITIAL_SUPPLY(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_constructorEmitsTheMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), address(this), 1_000_000_000e18);
        new Handshake();
    }

    function test_deployerIsWhoeverRanTheConstructor() public {
        vm.prank(alice);
        Handshake fresh = new Handshake();
        assertEq(fresh.balanceOf(alice), fresh.totalSupply());
        assertEq(fresh.balanceOf(address(this)), 0);
    }

    function test_thereIsNoMintOrAdminEntryPoint() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "setMinter(address)",
            "transferOwnership(address)",
            "initialize(address)",
            "upgradeTo(address)",
            "unpause()"
        ];
        uint256 supply = token.totalSupply();
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(alice);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, type(uint128).max));
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), supply, signatures[i]);
            assertEq(token.balanceOf(alice), 0, signatures[i]);
        }
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4 && op != 0xF2 && op != 0xFF, "forbidden opcode");
        }
    }

    /* ------------------------------------------------------------------ transfer */

    function test_transferMovesExactlyTheAmount() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(this), alice, 100e18);
        assertTrue(token.transfer(alice, 100e18));

        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - 100e18);
    }

    function test_transferOfZeroIsAllowedAndChangesNothing() public {
        uint256 before = token.balanceOf(address(this));
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(address(this)), before);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferToSelfKeepsTheBalance() public {
        uint256 before = token.balanceOf(address(this));
        assertTrue(token.transfer(address(this), 10e18));
        assertEq(token.balanceOf(address(this)), before);
    }

    function test_revertWhen_transferExceedsBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Handshake.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_revertWhen_transferToZeroAddress() public {
        vm.expectRevert(Handshake.ZeroAddress.selector);
        token.transfer(address(0), 1e18);
    }

    /* ------------------------------------------------------------------ allowance */

    function test_approveSetsAndOverwritesTheAllowance() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(address(this), alice, 5e18);
        assertTrue(token.approve(alice, 5e18));
        assertEq(token.allowance(address(this), alice), 5e18);

        token.approve(alice, 1e18);
        assertEq(token.allowance(address(this), alice), 1e18);
    }

    function test_revertWhen_approvingZeroAddress() public {
        vm.expectRevert(Handshake.ZeroAddress.selector);
        token.approve(address(0), 1e18);
    }

    function test_transferFromSpendsTheAllowance() public {
        token.approve(alice, 10e18);

        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 4e18));

        assertEq(token.balanceOf(bob), 4e18);
        assertEq(token.allowance(address(this), alice), 6e18);
    }

    function test_maxAllowanceIsStillDecremented() public {
        token.approve(alice, type(uint256).max);

        vm.prank(alice);
        token.transferFrom(address(this), bob, 7e18);

        assertEq(token.allowance(address(this), alice), type(uint256).max - 7e18);
    }

    function test_revertWhen_transferFromExceedsAllowance() public {
        token.approve(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Handshake.InsufficientAllowance.selector, address(this), alice, 1e18, 2e18)
        );
        token.transferFrom(address(this), bob, 2e18);
    }

    function test_revertWhen_transferFromExceedsBalance() public {
        vm.prank(bob);
        token.approve(alice, 10e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Handshake.InsufficientBalance.selector, bob, 0, 5e18));
        token.transferFrom(bob, alice, 5e18);
    }

    function test_revertWhen_transferFromWithoutAnyApproval() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Handshake.InsufficientAllowance.selector, address(this), alice, 0, 1));
        token.transferFrom(address(this), alice, 1);
    }

    /* ------------------------------------------------------------------ properties */

    function testFuzz_transferConservesTheSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, token.totalSupply());

        token.transfer(to, amount);

        assertEq(token.balanceOf(address(this)) + token.balanceOf(to), token.totalSupply());
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function testFuzz_supplyNeverMovesWhateverCalldataArrives(bytes calldata data) public {
        vm.prank(alice);
        (bool ok,) = address(token).call(data);
        ok; // Most random calldata reverts; what matters is that nothing was minted.
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(alice), 0);
    }
}
