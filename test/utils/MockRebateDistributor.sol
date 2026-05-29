// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Minimal stand-in for the Optimism grant faucet (IOPGrantFaucet).
///      feeRebateEligible() returns false so execute()'s rebate hook is a no-op,
///      making openSwapV2Optimism behave identically to the original openSwapV2.
///      A real contract (not address(0)) is required: execute()'s success path
///      calls into this address, and a call to a codeless address reverts uncaught.
contract MockRebateDistributor {
    function feeRebateEligible() external pure returns (bool) {
        return false;
    }

    function openSwapFeeRebate(
        address,
        address,
        uint256,
        uint256,
        bool,
        uint256,
        uint256,
        uint256
    ) external {}
}
