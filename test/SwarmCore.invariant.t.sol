// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Harness} from "./utils/Harness.sol";
import {InvariantHarness} from "./utils/InvariantHarness.sol";
import {SwarmCore} from "../src/SwarmCore.sol";

/// @notice Drives the token with random sequences of bounded calls from a closed set of actors and keeps
/// a ghost ledger of what every balance and allowance should be. Every entry point either succeeds and
/// is mirrored in the ledger, or is deliberately given a bad input and is asserted to revert with the
/// exact error and to have moved nothing. The suite runs with `fail_on_revert`, so an assertion that
/// fails inside a handler fails the invariant run with the call sequence that caused it.
contract SwarmCoreHandler is Harness {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SwarmCore public immutable token;
    address public immutable deployer;

    address[] public actors;
    mapping(address => bool) public isActor;

    /// @dev Ghost ledger: what the token should report.
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    /// @dev Everything an actor ever received and ever sent, so a balance can be checked against its history.
    mapping(address => uint256) public ghostInflow;
    mapping(address => uint256) public ghostOutflow;
    /// @dev Sum of every amount successfully moved, in any direction.
    uint256 public ghostMoved;

    /// @dev Call counters, so a run can be checked for having exercised each path.
    uint256 public calls_transfer;
    uint256 public calls_transferFrom;
    uint256 public calls_approve;
    uint256 public calls_expectedReverts;

    constructor(SwarmCore token_, address deployer_, address[] memory others) {
        token = token_;
        deployer = deployer_;
        _addActor(deployer_);
        for (uint256 i = 0; i < others.length; i++) {
            _addActor(others[i]);
        }
        ghostBalance[deployer_] = SUPPLY;
        ghostInflow[deployer_] = SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---------------------------------------------------------------------------------------------
    // Happy paths: bounded so they succeed, then mirrored in the ledger
    // ---------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _transfer(from, to, amount);
    }

    /// @dev The whole balance, so the sender is left at exactly zero.
    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), token.balanceOf(from));
    }

    /// @dev One wei, the smallest non-zero amount.
    function transferOne(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        uint256 amount = token.balanceOf(from) > 0 ? 1 : 0;
        _transfer(from, _actor(toSeed), amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function approveUnlimited(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), type(uint256).max);
    }

    function approveZero(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), 0);
    }

    /// @dev Just below unlimited: only exactly `type(uint256).max` may be treated as unlimited, so these
    /// allowances must still be spent down by `transferFrom`.
    function approveAlmostUnlimited(uint256 ownerSeed, uint256 spenderSeed, uint256 below) external {
        below = bound(below, 1, SUPPLY);
        _approve(_actor(ownerSeed), _actor(spenderSeed), type(uint256).max - below);
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);

        uint256 allowed = token.allowance(from, spender);
        uint256 balance = token.balanceOf(from);
        uint256 ceiling = allowed == type(uint256).max ? balance : (allowed < balance ? allowed : balance);
        amount = bound(amount, 0, ceiling);

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 spenderBefore = token.balanceOf(spender);

        vm.prank(spender);
        bool ok = token.transferFrom(from, to, amount);
        assertTrue(ok, "transferFrom returned false");

        if (allowed == type(uint256).max) {
            assertEq(token.allowance(from, spender), type(uint256).max, "an unlimited allowance was reduced");
        } else {
            assertEq(token.allowance(from, spender), allowed - amount, "the allowance did not fall by the amount");
            ghostAllowance[from][spender] = allowed - amount;
        }
        _checkMoved(from, to, amount, fromBefore, toBefore);
        if (spender != from && spender != to) {
            assertEq(token.balanceOf(spender), spenderBefore, "the spender's own balance changed");
        }
        _record(from, to, amount);
        calls_transferFrom++;
    }

    // ---------------------------------------------------------------------------------------------
    // Failure paths: the input is chosen to be invalid, the call must revert with the exact error and
    // leave every balance and allowance where it was
    // ---------------------------------------------------------------------------------------------

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 amount = balance + bound(excess, 1, type(uint256).max - balance);

        bytes memory expected =
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, from, balance, amount);
        _expectRevert(from, abi.encodeWithSelector(token.transfer.selector, to, amount), expected);
        assertEq(token.balanceOf(from), balance, "a failed transfer changed the sender's balance");
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 balance = token.balanceOf(from);
        bytes memory expected = abi.encodeWithSelector(SwarmCore.ERC20InvalidReceiver.selector, address(0));
        _expectRevert(from, abi.encodeWithSelector(token.transfer.selector, address(0), amount), expected);
        assertEq(token.balanceOf(from), balance, "a failed transfer to zero changed the sender's balance");
    }

    function transferFromAboveAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(from, spender);
        uint256 balance = token.balanceOf(from);

        bytes memory expected;
        uint256 amount;
        if (allowed == type(uint256).max) {
            // Nothing is above an unlimited allowance; the balance is the only ceiling left.
            amount = balance + bound(excess, 1, type(uint256).max - balance);
            expected = abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, from, balance, amount);
        } else {
            amount = allowed + bound(excess, 1, type(uint256).max - allowed);
            expected = abi.encodeWithSelector(SwarmCore.ERC20InsufficientAllowance.selector, spender, allowed, amount);
        }
        _expectRevert(spender, abi.encodeWithSelector(token.transferFrom.selector, from, to, amount), expected);
        assertEq(token.allowance(from, spender), allowed, "a failed transferFrom changed the allowance");
        assertEq(token.balanceOf(from), balance, "a failed transferFrom changed the owner's balance");
    }

    function transferFromAboveBalance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 amount = balance + bound(excess, 1, type(uint256).max - balance);

        // Grant enough that only the balance stands in the way.
        _approve(from, spender, amount);
        bytes memory expected =
            abi.encodeWithSelector(SwarmCore.ERC20InsufficientBalance.selector, from, balance, amount);
        _expectRevert(spender, abi.encodeWithSelector(token.transferFrom.selector, from, to, amount), expected);
        assertEq(token.allowance(from, spender), amount, "a transferFrom that failed on balance spent allowance");
        assertEq(token.balanceOf(from), balance, "a failed transferFrom changed the owner's balance");
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        bytes memory expected = abi.encodeWithSelector(SwarmCore.ERC20InvalidSpender.selector, address(0));
        _expectRevert(owner, abi.encodeWithSelector(token.approve.selector, address(0), amount), expected);
        assertEq(token.allowance(owner, address(0)), 0, "the zero spender was granted an allowance");
    }

    /// @dev Any selector that is not part of the token's interface must be refused: there is no fallback,
    /// no hidden admin entry point, and no way to send ether.
    function callUnknownSelector(uint256 callerSeed, bytes4 selector, bytes calldata tail) external {
        if (_isKnownSelector(selector)) return;
        address caller = _actor(callerSeed);
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, tail));
        assertFalse(ok, "an unknown selector was accepted");
        calls_expectedReverts++;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) private {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        _checkMoved(from, to, amount, fromBefore, toBefore);
        _record(from, to, amount);
        calls_transfer++;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        uint256 ownerBalance = token.balanceOf(owner);
        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "approve returned false");
        assertEq(token.allowance(owner, spender), amount, "approve did not set exactly the amount");
        assertEq(token.balanceOf(owner), ownerBalance, "approve moved tokens");
        ghostAllowance[owner][spender] = amount;
        calls_approve++;
    }

    function _checkMoved(address from, address to, uint256 amount, uint256 fromBefore, uint256 toBefore) private view {
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "a self-transfer changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "the sender did not pay exactly the amount");
            assertEq(token.balanceOf(to), toBefore + amount, "the receiver did not get exactly the amount");
        }
    }

    function _record(address from, address to, uint256 amount) private {
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostOutflow[from] += amount;
        ghostInflow[to] += amount;
        ghostMoved += amount;
    }

    function _expectRevert(address caller, bytes memory data, bytes memory expected) private {
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(data);
        assertFalse(ok, "a call with an invalid input succeeded");
        assertTrue(keccak256(ret) == keccak256(expected), "the call reverted with a different error");
        calls_expectedReverts++;
    }

    function _isKnownSelector(bytes4 selector) private view returns (bool) {
        return selector == token.name.selector || selector == token.symbol.selector
            || selector == token.decimals.selector || selector == token.totalSupply.selector
            || selector == token.balanceOf.selector || selector == token.allowance.selector
            || selector == token.transfer.selector || selector == token.approve.selector
            || selector == token.transferFrom.selector || selector == token.DECIMALS.selector
            || selector == token.TOTAL_SUPPLY.selector;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _addActor(address account) private {
        if (isActor[account]) return;
        isActor[account] = true;
        actors.push(account);
    }
}

/// @notice Invariants of SwarmCore over random call sequences. The actor set is closed, so the sum of the
/// actors' balances is the whole supply and nothing can leak out of view: the zero address is refused,
/// and the token, the handler and the test contract are never valid receivers in a handler call.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmCoreInvariantTest is InvariantHarness {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    address internal constant DEPLOYER = address(0xFAC7);

    SwarmCore internal token;
    SwarmCoreHandler internal handler;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new SwarmCore();

        address[] memory others = new address[](7);
        others[0] = address(0xA11CE);
        others[1] = address(0xB0B);
        others[2] = address(0xCA201);
        others[3] = address(0xD157); // stands in for the distributor
        others[4] = address(0xC1A1); // stands in for a claimant
        others[5] = address(0x5BE4D); // stands in for a spender contract
        others[6] = address(0x7EAD); // never does anything but receive: a cold wallet
        handler = new SwarmCoreHandler(token, DEPLOYER, others);

        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferAll.selector;
        selectors[2] = handler.transferOne.selector;
        selectors[3] = handler.approve.selector;
        selectors[4] = handler.approveUnlimited.selector;
        selectors[5] = handler.approveZero.selector;
        selectors[6] = handler.approveAlmostUnlimited.selector;
        selectors[7] = handler.transferFrom.selector;
        selectors[8] = handler.transferAboveBalance.selector;
        selectors[9] = handler.transferToZero.selector;
        selectors[10] = handler.transferFromAboveAllowance.selector;
        selectors[11] = handler.transferFromAboveBalance.selector;
        selectors[12] = handler.approveZeroSpender.selector;
        selectors[13] = handler.callUnknownSelector.selector;
        // Weighted: plain transfers and spends are the common case on chain.
        selectors[14] = handler.transfer.selector;
        selectors[15] = handler.transferFrom.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Conservation: what the actors hold between them is exactly the fixed supply, always.
    function invariant_balancesSumToTheSupply() public view {
        uint256 sum;
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY, "the actors' balances do not sum to the supply");
    }

    /// @dev The supply never changes, by any sequence of calls, from anyone.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY, "totalSupply changed");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY, "TOTAL_SUPPLY changed");
        assertEq(uint256(token.decimals()), 18, "decimals changed");
    }

    /// @dev Internal accounting equals the model: every balance is what the ledger of successful calls says.
    function invariant_balancesMatchTheGhostLedger() public view {
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.ghostBalance(actor), "a balance disagrees with the ledger");
        }
    }

    /// @dev Nobody holds more than they received: balance == received - sent, where the deployer's
    /// receipt is the mint. Equivalently, nobody has ever sent more than they received.
    function invariant_nobodyHoldsMoreThanTheyReceived() public view {
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            address actor = handler.actors(i);
            uint256 inflow = handler.ghostInflow(actor);
            uint256 outflow = handler.ghostOutflow(actor);
            assertGe(inflow, outflow, "an actor sent more than it ever received");
            assertEq(token.balanceOf(actor), inflow - outflow, "a balance is not received minus sent");
        }
    }

    /// @dev Every allowance is what the last approve set, less what transferFrom spent, with unlimited
    /// allowances never spent.
    function invariant_allowancesMatchTheGhostLedger() public view {
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            address owner = handler.actors(i);
            for (uint256 j = 0; j < count; j++) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "an allowance disagrees with the ledger"
                );
            }
            assertEq(token.allowance(owner, address(0)), 0, "the zero spender holds an allowance");
        }
    }

    /// @dev Nothing leaks to an address outside the actor set: not the zero address, not the token, not
    /// the harness contracts.
    function invariant_outsidersHoldNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "the token holds tokens");
        assertEq(token.balanceOf(address(handler)), 0, "the handler holds tokens");
        assertEq(token.balanceOf(address(this)), 0, "the test contract holds tokens");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    /// @dev The deployer's balance is the supply less everything it has sent net: the launch factory can
    /// always account for what it still holds.
    function invariant_deployerBalanceIsSupplyLessNetOutflow() public view {
        uint256 inflow = handler.ghostInflow(DEPLOYER);
        uint256 outflow = handler.ghostOutflow(DEPLOYER);
        assertGe(inflow, SUPPLY, "the deployer's recorded receipts are below the mint");
        assertEq(token.balanceOf(DEPLOYER), inflow - outflow, "the deployer's balance is off");
        assertLt(token.balanceOf(DEPLOYER), SUPPLY + 1, "the deployer holds more than the supply");
    }
}
