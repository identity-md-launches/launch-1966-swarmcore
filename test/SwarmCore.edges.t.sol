// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Harness} from "./utils/Harness.sol";
import {SwarmCore} from "../src/SwarmCore.sol";

/// @notice Performs a launch the way the factory does, in a single transaction: deploys the token and
/// forwards the swarm's tenth, the pool's share and the requester's remainder, all inside one constructor.
/// A test that did these as separate calls would run each as its own transaction, which the chain does not.
contract OneTransactionLaunch {
    SwarmCore public immutable token;
    uint256 public immutable supplyMinted;
    uint256 public immutable factoryAfter;

    constructor(address distributor, address pool, address requester, uint256 swarmBps, uint256 poolBps) {
        token = new SwarmCore();
        supplyMinted = token.balanceOf(address(this));
        uint256 supply = token.totalSupply();
        uint256 swarm = (supply * swarmBps) / 10_000;
        uint256 seed = (supply * poolBps) / 10_000;
        require(token.transfer(distributor, swarm), "swarm transfer returned false");
        require(token.transfer(pool, seed), "seed transfer returned false");
        require(token.transfer(requester, supply - swarm - seed), "remainder transfer returned false");
        factoryAfter = token.balanceOf(address(this));
    }
}

/// @notice The inputs the implementation did not necessarily consider: the maximum, one below the
/// maximum, the same call twice, malformed calldata, the order of two failing checks, and the launch
/// done in one transaction.
/// forge-config: default.fuzz.runs = 1000
contract SwarmCoreEdgesTest is Harness {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant MAX = type(uint256).max;

    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5BE4D);

    SwarmCore internal token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new SwarmCore();
    }

    // ---------------------------------------------------------------------------------------------
    // The maximum and one below it
    // ---------------------------------------------------------------------------------------------

    function test_allowanceOfMaxMinusOneIsNotUnlimited() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, MAX - 1);

        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 1);
        assertEq(token.allowance(DEPLOYER, SPENDER), MAX - 2, "only exactly max is unlimited");

        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, SUPPLY - 1);
        assertEq(token.allowance(DEPLOYER, SPENDER), MAX - 1 - SUPPLY, "every spend is deducted");
        assertEq(token.balanceOf(BOB), SUPPLY, "bob received everything");
    }

    function testFuzz_nearUnlimitedAllowanceIsSpentDown(uint256 below, uint256 amount) public {
        below = bound(below, 1, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        token.approve(SPENDER, MAX - below);

        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, amount);
        assertEq(token.allowance(DEPLOYER, SPENDER), MAX - below - amount, "the allowance fell by the amount");
    }

    function testFuzz_approveStoresAnyValueExactly(uint256 value) public {
        vm.prank(ALICE);
        token.approve(SPENDER, value);
        assertEq(token.allowance(ALICE, SPENDER), value, "the allowance is exactly the value asked for");
        assertEq(token.allowance(SPENDER, ALICE), 0, "the allowance is directional");
        assertEq(token.balanceOf(ALICE), 0, "approve moved no tokens");
    }

    function test_transferOfMaxUintReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, MAX));
        vm.prank(DEPLOYER);
        token.transfer(ALICE, MAX);

        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, ALICE, 0, MAX));
        vm.prank(ALICE);
        token.transfer(BOB, MAX);
    }

    function test_transferOfSupplyPlusOneReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, SUPPLY + 1)
        );
        vm.prank(DEPLOYER);
        token.transfer(ALICE, SUPPLY + 1);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "nothing moved");
    }

    function test_transferFromOfMaxUintWithUnlimitedAllowanceReverts() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, MAX);
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, MAX));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, MAX);
        assertEq(token.allowance(DEPLOYER, SPENDER), MAX, "the allowance is untouched");
    }

    // ---------------------------------------------------------------------------------------------
    // The same call twice
    // ---------------------------------------------------------------------------------------------

    function test_theSameTransferTwiceFailsOnceTheBalanceIsSpent() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 5 ether);

        vm.prank(ALICE);
        token.transfer(BOB, 5 ether);

        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, ALICE, 0, 5 ether));
        vm.prank(ALICE);
        token.transfer(BOB, 5 ether);
        assertEq(token.balanceOf(BOB), 5 ether, "the second call moved nothing");
    }

    function test_theSameTransferFromTwiceFailsOnceTheAllowanceIsSpent() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 5 ether);

        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 5 ether);

        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, SPENDER, 0, 5 ether));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 5 ether);
        assertEq(token.balanceOf(BOB), 5 ether, "the second call moved nothing");
    }

    function test_approveEmitsEveryTimeEvenWhenUnchanged() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(DEPLOYER, SPENDER, 3 ether);
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 3 ether);

        vm.expectEmit(true, true, false, true);
        emit Approval(DEPLOYER, SPENDER, 3 ether);
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 3 ether);
        assertEq(token.allowance(DEPLOYER, SPENDER), 3 ether, "the allowance is what was set");
    }

    function test_approveResetToZeroBlocksTheSpender() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, MAX);
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 0);

        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Which check fires first, and who may be whom
    // ---------------------------------------------------------------------------------------------

    function test_allowanceIsCheckedBeforeBalance() public {
        // Alice holds nothing and the spender is allowed 1: asking for 2 fails on the allowance.
        vm.prank(ALICE);
        token.approve(SPENDER, 1);
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, SPENDER, 1, 2));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 2);

        // Within the allowance, the empty balance is what fails.
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
        assertEq(token.allowance(ALICE, SPENDER), 1, "a failure on balance did not spend the allowance");
    }

    function test_receiverIsCheckedBeforeBalance() public {
        // An empty sender to the zero address: the receiver check fires, not the balance check.
        vm.expectRevert(abi.encodeWithSelector(SwarmCore.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transfer(address(0), 1);
    }

    function test_transferFromOfZeroNeedsNoAllowanceAndMovesNothing() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(DEPLOYER, BOB, 0);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, BOB, 0), "a zero transferFrom succeeds");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "nothing left the owner");
        assertEq(token.balanceOf(BOB), 0, "nothing reached bob");
        assertEq(token.allowance(DEPLOYER, SPENDER), 0, "no allowance was created or spent");
    }

    function test_holderMayApproveAndSpendFromThemself() public {
        vm.prank(DEPLOYER);
        token.approve(DEPLOYER, 2 ether);
        vm.prank(DEPLOYER);
        token.transferFrom(DEPLOYER, BOB, 2 ether);
        assertEq(token.balanceOf(BOB), 2 ether, "the tokens moved");
        assertEq(token.allowance(DEPLOYER, DEPLOYER), 0, "the self-allowance was spent like any other");
    }

    function test_spenderMaySendToThemself() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 2 ether);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, SPENDER, 2 ether);
        assertEq(token.balanceOf(SPENDER), 2 ether, "the spender received the tokens");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 2 ether, "the owner paid them");
    }

    function test_transferFromToTheOwnerSpendsTheAllowanceAndChangesNothingElse() public {
        vm.prank(DEPLOYER);
        token.approve(SPENDER, 2 ether);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, DEPLOYER, 2 ether);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "a round trip to the owner keeps the balance");
        assertEq(token.allowance(DEPLOYER, SPENDER), 0, "but the allowance was still spent");
    }

    function test_unknownAccountsReadAsZero() public view {
        assertEq(token.balanceOf(address(0)), 0, "zero address");
        assertEq(token.balanceOf(address(token)), 0, "the token");
        assertEq(token.balanceOf(address(0xDEAD)), 0, "a stranger");
        assertEq(token.allowance(DEPLOYER, SPENDER), 0, "an allowance never set");
        assertEq(token.allowance(address(0), DEPLOYER), 0, "an allowance from the zero address");
    }

    // ---------------------------------------------------------------------------------------------
    // Malformed calldata
    // ---------------------------------------------------------------------------------------------

    function test_truncatedCalldataIsRefused() public {
        bytes memory full = abi.encodeWithSelector(token.transfer.selector, ALICE, 1 ether);
        bytes memory truncated = new bytes(full.length - 32);
        for (uint256 i = 0; i < truncated.length; i++) {
            truncated[i] = full[i];
        }
        vm.prank(DEPLOYER);
        (bool ok,) = address(token).call(truncated);
        assertFalse(ok, "a transfer with a missing argument was accepted");
        assertEq(token.balanceOf(ALICE), 0, "nothing moved");
    }

    function test_dirtyAddressBitsAreRefused() public {
        bytes32 dirty = bytes32(uint256(uint160(ALICE)) | (uint256(1) << 160));
        vm.prank(DEPLOYER);
        (bool ok,) = address(token).call(abi.encodeWithSelector(token.transfer.selector, dirty, uint256(1 ether)));
        assertFalse(ok, "an address with dirty high bits was accepted");
        assertEq(token.balanceOf(ALICE), 0, "nothing moved");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY, "nothing left");
    }

    function test_emptyCalldataIsRefused() public {
        vm.prank(DEPLOYER);
        (bool ok,) = address(token).call("");
        assertFalse(ok, "an empty call was accepted: there must be no receive");
        (ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "ether was accepted");
    }

    function testFuzz_unknownSelectorsAreRefused(bytes4 selector, bytes calldata tail, address caller) public {
        if (
            selector == token.name.selector || selector == token.symbol.selector || selector == token.decimals.selector
                || selector == token.totalSupply.selector || selector == token.balanceOf.selector
                || selector == token.allowance.selector || selector == token.transfer.selector
                || selector == token.approve.selector || selector == token.transferFrom.selector
                || selector == token.DECIMALS.selector || selector == token.TOTAL_SUPPLY.selector
        ) {
            return;
        }
        if (caller == address(vm)) caller = ALICE;
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, tail));
        assertFalse(ok, "a selector outside the ERC-20 interface was accepted");
        assertEq(token.totalSupply(), SUPPLY, "the supply is unchanged");
    }

    // ---------------------------------------------------------------------------------------------
    // The launch in one transaction
    // ---------------------------------------------------------------------------------------------

    function test_launchInOneTransactionDeliversEveryFlowWhole() public {
        address distributor = address(0xD157);
        address pool = address(0x9001);
        address requester = address(0x4E0);

        OneTransactionLaunch launch = new OneTransactionLaunch(distributor, pool, requester, 1_000, 8_000);
        SwarmCore launched = launch.token();

        assertEq(launch.supplyMinted(), SUPPLY, "the factory received the whole supply in its constructor");
        assertEq(launch.factoryAfter(), 0, "the factory paid everything out in the same transaction");
        assertEq(launched.balanceOf(distributor), SUPPLY / 10, "the swarm's tenth arrived whole");
        assertEq(launched.balanceOf(pool), (SUPPLY * 8_000) / 10_000, "the seed arrived whole");
        assertEq(launched.balanceOf(requester), SUPPLY / 10, "the remainder arrived whole");
        assertEq(launched.balanceOf(address(launch)), 0, "nothing stayed behind");
        assertEq(launched.totalSupply(), SUPPLY, "the supply is unchanged");
    }

    function testFuzz_launchInOneTransactionWithAnyPoolShare(uint256 poolBps) public {
        poolBps = bound(poolBps, 0, 9_000);
        OneTransactionLaunch launch =
            new OneTransactionLaunch(address(0xD157), address(0x9001), address(0x4E0), 1_000, poolBps);
        SwarmCore launched = launch.token();
        uint256 swarm = SUPPLY / 10;
        uint256 seed = (SUPPLY * poolBps) / 10_000;
        assertEq(launched.balanceOf(address(0xD157)), swarm, "swarm");
        assertEq(launched.balanceOf(address(0x9001)), seed, "pool");
        assertEq(launched.balanceOf(address(0x4E0)), SUPPLY - swarm - seed, "requester");
        assertEq(launch.factoryAfter(), 0, "factory");
    }

    // ---------------------------------------------------------------------------------------------
    // Many small moves
    // ---------------------------------------------------------------------------------------------

    function testFuzz_manySmallTransfersAmongThreeConserveTheSupply(uint8 steps, uint256 seed) public {
        address[3] memory who = [DEPLOYER, ALICE, BOB];
        for (uint256 i = 0; i < steps; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address from = who[r % 3];
            address to = who[(r / 3) % 3];
            uint256 amount = bound(r / 9, 0, token.balanceOf(from));
            vm.prank(from);
            assertTrue(token.transfer(to, amount), "transfer returned false");
        }
        assertEq(
            token.balanceOf(DEPLOYER) + token.balanceOf(ALICE) + token.balanceOf(BOB),
            SUPPLY,
            "the three balances always sum to the supply"
        );
    }
}
