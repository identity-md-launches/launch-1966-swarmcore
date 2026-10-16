// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Harness, Vm} from "./utils/Harness.sol";
import {SwarmCore} from "../src/SwarmCore.sol";

/// @notice Behaviour of the SwarmCore token: metadata, the single mint, transfers, allowances, the
/// absence of any privileged or supply-changing entry point, and the launch flows the factory performs.
contract SwarmCoreTest is Harness {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant SWARM_BPS = 1_000;

    /// @dev Stands in for the launch factory: the address that deploys the token and receives the supply.
    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5BE4D);
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant ATTACKER = address(0xBEEF);

    SwarmCore internal token;

    function setUp() public {
        vm.label(DEPLOYER, "deployer");
        vm.label(ALICE, "alice");
        vm.label(BOB, "bob");
        vm.prank(DEPLOYER);
        token = new SwarmCore();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and the single mint
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "SwarmCore", "name");
        assertEq(token.symbol(), "SWARMCORE", "symbol");
        assertEq(uint256(token.decimals()), 18, "decimals");
        assertEq(uint256(token.DECIMALS()), 18, "DECIMALS constant");
        assertEq(token.totalSupply(), SUPPLY, "totalSupply");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY, "TOTAL_SUPPLY constant");
    }

    function test_constructorMintsTheWholeSupplyToTheDeployer() public view {
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "the deployer holds the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the test contract, which did not deploy, holds nothing");
        assertEq(token.balanceOf(address(token)), 0, "the token itself holds nothing");
    }

    function test_constructorEmitsOneMintTransfer() public {
        vm.recordLogs();
        vm.prank(ALICE);
        SwarmCore fresh = new SwarmCore();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "exactly one event is emitted at deployment");
        assertEq(logs[0].emitter, address(fresh), "the token emitted it");
        assertEq(logs[0].topics.length, 3, "Transfer has two indexed arguments");
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"), "the event is Transfer");
        assertEq(logs[0].topics[1], bytes32(0), "minted from the zero address");
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(ALICE))), "minted to the deployer");
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY, "the whole supply was minted");
        assertEq(fresh.balanceOf(ALICE), SUPPLY, "whoever deploys receives the supply");
    }

    // ---------------------------------------------------------------------------------------------
    // transfer
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactlyTheAmountAndEmits() public {
        uint256 amount = 123_456 * 10 ** 18;

        vm.expectEmit(true, true, false, true);
        emit Transfer(DEPLOYER, ALICE, amount);
        vm.prank(DEPLOYER);
        bool ok = token.transfer(ALICE, amount);

        assertTrue(ok, "transfer returns true");
        assertEq(token.balanceOf(ALICE), amount, "the receiver got exactly the amount");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount, "the sender paid exactly the amount");
        assertEq(token.totalSupply(), SUPPLY, "the supply is unchanged");
    }

    function test_transferOfTheWholeBalanceSucceeds() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, SUPPLY);
        assertEq(token.balanceOf(ALICE), SUPPLY, "alice holds everything");
        assertEq(token.balanceOf(DEPLOYER), 0, "the deployer holds nothing");
    }

    function test_transferOfZeroSucceedsAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0), "a zero transfer from an empty account succeeds");
        assertEq(token.balanceOf(BOB), 0, "nothing moved");
    }

    function test_transferToSelfKeepsTheBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10 ether);
        vm.prank(ALICE);
        token.transfer(ALICE, 10 ether);
        assertEq(token.balanceOf(ALICE), 10 ether, "a self-transfer neither creates nor destroys tokens");
        assertEq(token.totalSupply(), SUPPLY, "the supply is unchanged");
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 5 ether);

        vm.expectRevert(
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, ALICE, 5 ether, 5 ether + 1)
        );
        vm.prank(ALICE);
        token.transfer(BOB, 5 ether + 1);

        assertEq(token.balanceOf(ALICE), 5 ether, "nothing moved");
        assertEq(token.balanceOf(BOB), 0, "nothing arrived");
    }

    function test_transferRevertsFromAnEmptyAccount() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    function test_transferToTheZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(DEPLOYER);
        token.transfer(address(0), 1);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "nothing was burned");
    }

    // ---------------------------------------------------------------------------------------------
    // approve / transferFrom
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsTheAllowanceAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(DEPLOYER, SPENDER, 7 ether);
        vm.prank(DEPLOYER);
        assertTrue(token.approve(SPENDER, 7 ether), "approve returns true");
        assertEq(token.allowance(DEPLOYER, SPENDER), 7 ether, "the allowance is set");

        vm.prank(DEPLOYER);
        token.approve(SPENDER, 2 ether);
        assertEq(token.allowance(DEPLOYER, SPENDER), 2 ether, "approve overwrites, it does not add");
    }

    function test_approveTheZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InvalidSpender.selector, address(0)));
        vm.prank(DEPLOYER);
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsTheAllowanceAndMovesTheTokens() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 10 ether);

        vm.expectEmit(true, true, false, true);
        emit Transfer(DEPLOYER, BOB, 4 ether);
        vm.prank(SPENDER);
        bool ok = token.transferFrom(DEPLOYER, BOB, 4 ether);

        assertTrue(ok, "transferFrom returns true");
        assertEq(token.balanceOf(BOB), 4 ether, "bob received exactly the amount");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 4 ether, "the owner paid exactly the amount");
        assertEq(token.balanceOf(SPENDER), 0, "the spender received nothing");
        assertEq(token.allowance(DEPLOYER, SPENDER), 6 ether, "the allowance went down by the amount");
    }

    function test_transferFromWithUnlimitedAllowanceKeepsIt() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, type(uint256).max);

        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 4 ether);

        assertEq(token.allowance(DEPLOYER, SPENDER), type(uint256).max, "an unlimited allowance stays unlimited");
        assertEq(token.balanceOf(BOB), 4 ether, "the tokens moved");
    }

    function test_transferFromWithoutAllowanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 1);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "nothing moved");
    }

    function test_transferFromAboveAllowanceReverts() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 3 ether);

        vm.expectRevert(
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, SPENDER, 3 ether, 3 ether + 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 3 ether + 1);

        assertEq(token.allowance(DEPLOYER, SPENDER), 3 ether, "the allowance is untouched");
        assertEq(token.balanceOf(BOB), 0, "nothing arrived");
    }

    function test_transferFromAboveBalanceRevertsEvenWithAllowance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, ALICE, 1 ether, 1 ether + 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1 ether + 1);
    }

    function test_transferFromToTheZeroAddressReverts() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, address(0), 1 ether);
    }

    function test_transferFromByTheOwnerStillNeedsAnAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, DEPLOYER, 0, 1));
        vm.prank(DEPLOYER);
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // No supply growth, no privileged hand
    // ---------------------------------------------------------------------------------------------

    /// @dev Mirrors the launch floor: none of the usual admin or mint entry points exist, from a
    /// stranger or from the deployer, and the supply never grows.
    function test_noCommonAdminCallIncreasesSupply() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ATTACKER, type(uint128).max);
            vm.prank(ATTACKER);
            (bool okAttacker,) = address(token).call(data);
            assertFalse(okAttacker, signatures[i]);
            vm.prank(DEPLOYER);
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(ATTACKER), 0, signatures[i]);
        }
    }

    /// @dev Mirrors the launch floor: nothing the deployer can call moves or freezes a holder.
    function test_noPrivilegedHandMovesOrFreezesAHolder() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, SUPPLY / 1_000);
        uint256 held = token.balanceOf(ALICE);
        assertGt(held, 0, "the holder received something");

        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, true);
            vm.prank(DEPLOYER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }

        vm.prank(DEPLOYER);
        (bool moved,) = address(token).call(abi.encodeWithSelector(token.transferFrom.selector, ALICE, DEPLOYER, 1));
        assertFalse(moved, "the deployer cannot pull from a holder without an allowance");
        assertEq(token.balanceOf(ALICE), held, "the holder's balance is untouched");

        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, held / 2), "the holder can still transfer");
        assertEq(token.balanceOf(BOB), held / 2, "the holder's transfer delivered in full");
    }

    function test_noOwnerAndNoPauseState() public {
        (bool hasOwner,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(hasOwner, "there is no owner");
        (bool hasPaused,) = address(token).call(abi.encodeWithSignature("paused()"));
        assertFalse(hasPaused, "there is no pause");
        (bool hasBurn,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(hasBurn, "there is no burn");
    }

    function test_plainEtherIsRefused() public {
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token has no receive or fallback");
        assertEq(address(token).balance, 0, "the token holds no ether");
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flows
    // ---------------------------------------------------------------------------------------------

    /// @dev The flows the factory performs: the swarm's tenth goes to the distributor whole, a claim
    /// leaves the distributor whole, and the remainder reaches the requester whole.
    function test_launchFlowsArriveWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 remainder = SUPPLY - swarm;

        vm.prank(DEPLOYER);
        assertTrue(token.transfer(DISTRIBUTOR, swarm), "the transfer to the distributor returned false");
        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "the swarm's share arrived whole");

        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm), "the claim transfer returned false");
        assertEq(token.balanceOf(CLAIMANT), swarm, "the claim arrived whole");
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "the distributor kept nothing back");

        vm.prank(DEPLOYER);
        assertTrue(token.transfer(BOB, remainder), "the transfer of the remainder returned false");
        assertEq(token.balanceOf(BOB), remainder, "the remainder arrived whole");
        assertEq(token.balanceOf(DEPLOYER), 0, "the factory paid everything out");
        assertEq(token.totalSupply(), SUPPLY, "the launch flows did not change the supply");
    }

    function test_runtimeHasNoDelegatecallOrSelfdestructAndFitsEip170() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0, "the token has runtime code");
        assertLe(runtime.length, 24_576, "the runtime fits EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "runtime contains DELEGATECALL");
            assertTrue(op != 0xF2, "runtime contains CALLCODE");
            assertTrue(op != 0xFF, "runtime contains SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesTheSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);

        vm.prank(DEPLOYER);
        assertTrue(token.transfer(to, amount), "transfer returns true");

        if (to == DEPLOYER) {
            assertEq(token.balanceOf(DEPLOYER), SUPPLY, "a self-transfer changes nothing");
        } else {
            assertEq(token.balanceOf(to), amount, "the receiver got exactly the amount");
            assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount, "the sender paid exactly the amount");
        }
        assertEq(token.totalSupply(), SUPPLY, "the supply is unchanged");
    }

    function testFuzz_transferAboveTheBalanceReverts(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY - 1);
        excess = bound(excess, 1, SUPPLY - held);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, held);

        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, ALICE, held, held + excess));
        vm.prank(ALICE);
        token.transfer(BOB, held + excess);

        assertEq(token.balanceOf(ALICE), held, "nothing moved");
    }

    function testFuzz_transferFromSpendsExactlyTheAmount(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, allowed);
        vm.prank(DEPLOYER);
        token.approve(SPENDER, allowed);

        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, BOB, amount), "transferFrom returns true");

        assertEq(token.allowance(DEPLOYER, SPENDER), allowed - amount, "the allowance went down by the amount");
        assertEq(token.balanceOf(BOB), amount, "bob got exactly the amount");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount, "the owner paid exactly the amount");
    }

    function testFuzz_transferFromAboveTheAllowanceReverts(uint256 allowed, uint256 excess) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        excess = bound(excess, 1, SUPPLY - allowed);
        vm.prank(DEPLOYER);
        token.approve(SPENDER, allowed);

        vm.expectRevert(
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, SPENDER, allowed, allowed + excess)
        );
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, allowed + excess);

        assertEq(token.allowance(DEPLOYER, SPENDER), allowed, "the allowance is untouched");
    }

    function testFuzz_aChainOfTransfersConservesTheSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);

        vm.prank(DEPLOYER);
        token.transfer(ALICE, a);
        vm.prank(ALICE);
        token.transfer(BOB, b);
        vm.prank(BOB);
        token.transfer(CLAIMANT, c);

        assertEq(token.balanceOf(DEPLOYER), SUPPLY - a, "deployer");
        assertEq(token.balanceOf(ALICE), a - b, "alice");
        assertEq(token.balanceOf(BOB), b - c, "bob");
        assertEq(token.balanceOf(CLAIMANT), c, "claimant");
        uint256 sum =
            token.balanceOf(DEPLOYER) + token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(CLAIMANT);
        assertEq(sum, SUPPLY, "the balances always sum to the supply");
        assertEq(token.totalSupply(), SUPPLY, "the supply is unchanged");
    }
}
