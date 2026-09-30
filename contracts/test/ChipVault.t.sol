// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "./Fixture.sol";
import {ChipVault} from "../src/ChipVault.sol";
import {IChip} from "../src/interfaces/IChip.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ChipVaultTest is Fixture {
    uint256 internal carolKey = 0xC0FFEE;
    address internal carol = vm.addr(carolKey);

    function setUp() public override {
        super.setUp();
        // Generate fees: 1_000 BLUE minted at 0.30% -> 3 BLUE in the vault.
        _mintAs(alice, 1_000e18);
        vm.startPrank(owner);
        chip.transfer(alice, 1_000_000_000e18);
        chip.transfer(carol, 1_000_000_000e18);
        vm.stopPrank();
    }

    function test_constructor_rejectsZero() public {
        vm.expectRevert(ChipVault.ZeroAddress.selector);
        new ChipVault(IERC20(address(0)), IChip(address(chip)));
        vm.expectRevert(ChipVault.ZeroAddress.selector);
        new ChipVault(IERC20(address(fund)), IChip(address(0)));
    }

    function test_feesArriveInVault() public view {
        assertEq(vault.totalBacking(), 3e18);
        assertEq(fund.balanceOf(address(vault)), 3e18);
        // 3 BLUE over 100B CHIP.
        assertEq(vault.backingPerChip(), 3e18 * 1e18 / chip.totalSupply());
    }

    function test_claim_paysProRataAndBurns() public {
        uint256 amount = 1_000_000_000e18; // 1% of supply
        uint256 expected = 3e18 * amount / chip.totalSupply();
        assertEq(vault.previewClaim(amount), expected);
        uint256 supplyBefore = chip.totalSupply();

        vm.startPrank(alice);
        chip.approve(address(vault), amount);
        uint256 out = vault.claim(amount, expected, bob);
        vm.stopPrank();

        assertEq(out, expected);
        assertEq(fund.balanceOf(bob), expected);
        assertEq(chip.balanceOf(alice), 0);
        assertEq(chip.totalSupply(), supplyBefore - amount);
        assertEq(chip.balanceOf(address(vault)), 0);
    }

    function test_claim_slippageAndZero() public {
        vm.startPrank(alice);
        chip.approve(address(vault), type(uint256).max);
        uint256 out = vault.previewClaim(1e18);
        vm.expectRevert(abi.encodeWithSelector(ChipVault.Slippage.selector, out, out + 1));
        vault.claim(1e18, out + 1, alice);
        vm.expectRevert(ChipVault.ZeroAmount.selector);
        vault.claim(0, 0, alice);
        vm.expectRevert(ChipVault.ZeroAddress.selector);
        vault.claim(1e18, 0, address(0));
        // Dust that would pay nothing is refused rather than burned for free.
        vm.expectRevert(abi.encodeWithSelector(ChipVault.Slippage.selector, 0, 0));
        vault.claim(1, 0, alice);
        vm.stopPrank();
    }

    function test_claim_needsAllowance() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.claim(1e18, 0, alice);
    }

    function test_claimWithPermit() public {
        uint256 amount = 500_000_000e18;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(carol, address(vault), amount, chip.nonces(carol), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(carolKey, digest);
        uint256 expected = vault.previewClaim(amount);

        vm.prank(carol);
        uint256 out = vault.claimWithPermit(amount, expected, carol, deadline, v, r, s);
        assertEq(out, expected);
        assertEq(fund.balanceOf(carol), expected);
        assertEq(chip.balanceOf(carol), 500_000_000e18);
    }

    function test_claimWithPermit_survivesFrontRunPermit() public {
        uint256 amount = 1e24;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(carol, address(vault), amount, chip.nonces(carol), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(carolKey, digest);
        chip.permit(carol, address(vault), amount, deadline, v, r, s); // someone replays it first

        vm.prank(carol);
        uint256 out = vault.claimWithPermit(amount, 0, carol, deadline, v, r, s);
        assertGt(out, 0);
    }

    function test_strayChipIsBurnedForEveryone() public {
        vm.prank(owner);
        chip.transfer(address(vault), 2_000_000_000e18);
        uint256 supply = chip.totalSupply();

        vm.startPrank(alice);
        chip.approve(address(vault), 1e24);
        vault.claim(1e24, 0, alice);
        vm.stopPrank();

        assertEq(chip.balanceOf(address(vault)), 0);
        assertEq(chip.totalSupply(), supply - 1e24 - 2_000_000_000e18);
    }

    /// Backing per CHIP never drops: mints add BLUE, claims remove BLUE and CHIP at the same ratio.
    function testFuzz_backingNeverDecreases(uint256 claimAmt, uint256 mintShares) public {
        claimAmt = bound(claimAmt, 1e20, chip.balanceOf(alice));
        mintShares = bound(mintShares, 1e15, 10_000e18);

        uint256 b0 = vault.totalBacking();
        uint256 s0 = chip.totalSupply();

        vm.startPrank(alice);
        chip.approve(address(vault), claimAmt);
        vault.claim(claimAmt, 0, alice);
        vm.stopPrank();
        uint256 b1 = vault.totalBacking();
        uint256 s1 = chip.totalSupply();
        assertGe(b1 * s0, b0 * s1);

        _mintAs(bob, mintShares);
        assertGe(vault.totalBacking() * s1, b1 * chip.totalSupply());
    }

    function _permitDigest(address o, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                o,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", chip.DOMAIN_SEPARATOR(), structHash));
    }
}
