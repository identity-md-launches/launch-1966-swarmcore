// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The subset of Foundry cheatcodes these tests use, declared here so the project needs no
/// vendored test library. The signatures are Foundry's own (see forge-std's `Vm.sol`).
interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function expectRevert() external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
    function assume(bool condition) external pure;
    function label(address account, string calldata newLabel) external;
}

/// @notice A small assertion base. A failed assertion reverts, which fails the test; the revert data
/// names the assertion and carries both values so a failure is readable in the trace.
abstract contract Harness {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error AssertionFailed(string reason);
    error AssertionFailedUint(string reason, uint256 left, uint256 right);
    error AssertionFailedAddress(string reason, address left, address right);
    error AssertionFailedBytes32(string reason, bytes32 left, bytes32 right);
    error AssertionFailedString(string reason, string left, string right);

    function assertTrue(bool condition, string memory reason) internal pure {
        if (!condition) revert AssertionFailed(reason);
    }

    function assertFalse(bool condition, string memory reason) internal pure {
        if (condition) revert AssertionFailed(reason);
    }

    function assertEq(uint256 left, uint256 right, string memory reason) internal pure {
        if (left != right) revert AssertionFailedUint(reason, left, right);
    }

    function assertEq(address left, address right, string memory reason) internal pure {
        if (left != right) revert AssertionFailedAddress(reason, left, right);
    }

    function assertEq(bytes32 left, bytes32 right, string memory reason) internal pure {
        if (left != right) revert AssertionFailedBytes32(reason, left, right);
    }

    function assertEq(string memory left, string memory right, string memory reason) internal pure {
        if (keccak256(bytes(left)) != keccak256(bytes(right))) revert AssertionFailedString(reason, left, right);
    }

    function assertLe(uint256 left, uint256 right, string memory reason) internal pure {
        if (left > right) revert AssertionFailedUint(reason, left, right);
    }

    function assertGt(uint256 left, uint256 right, string memory reason) internal pure {
        if (left <= right) revert AssertionFailedUint(reason, left, right);
    }

    /// @dev Maps an arbitrary fuzz input into `[min, max]` without rejecting inputs.
    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (min > max) revert AssertionFailedUint("bound: min > max", min, max);
        uint256 size = max - min;
        if (size == type(uint256).max) return x;
        return min + (x % (size + 1));
    }
}
