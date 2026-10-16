// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Harness} from "./Harness.sol";

/// @notice The invariant-runner plumbing forge-std's `StdInvariant` provides, declared here because the
/// project vendors no test library. Forge's invariant runner calls `targetContracts()` and
/// `targetSelectors()` on the test contract, if they exist, to learn what to fuzz; the shapes below are
/// the ones it decodes (`address[]` and `(address, bytes4[])[]`).
abstract contract InvariantHarness is Harness {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    address[] private _targetedContracts;
    FuzzSelector[] private _targetedSelectors;

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function targetSelectors() public view returns (FuzzSelector[] memory) {
        return _targetedSelectors;
    }

    function targetContract(address target) internal {
        _targetedContracts.push(target);
    }

    function targetSelector(FuzzSelector memory selector) internal {
        _targetedSelectors.push(selector);
    }

    function assertGe(uint256 left, uint256 right, string memory reason) internal pure {
        if (left < right) revert AssertionFailedUint(reason, left, right);
    }

    function assertLt(uint256 left, uint256 right, string memory reason) internal pure {
        if (left >= right) revert AssertionFailedUint(reason, left, right);
    }
}
