// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle2} from "./IOpenOracle2.sol";

interface IOpenOracleBounty2 {
    struct Bounties {
        uint256 totalAmtDeposited;
        uint256 bountyStartAmt;
        uint256 bountyClaimed;
        uint256 start;
        uint256 roundLength;
        uint256 recallUnlockAt;
        address payable creator;
        address bountyToken;
        uint16 bountyMultiplier;
        uint16 maxRounds;
        bool claimed;
        bool recalled;
        bool storeReportId;
    }

    function createOracleBounty(IOpenOracle2.OracleGame calldata oracleGame, Bounties calldata bounty)
        external
        payable
        returns (uint256 bountyId);

    function recallBounty(uint256 bountyId, IOpenOracle2.OracleGame calldata oracleGame, Bounties calldata bounty)
        external;

    function claimBounty(
        uint256 bountyId,
        uint128 amount2,
        IOpenOracle2.OracleGame calldata oracleGame,
        Bounties calldata bounty,
        IOpenOracle2.TimingBoundaries calldata timing
    ) external returns (uint256 reportId);

    function getTempHolding(address tokenToGet, address _to) external;

    function nextBountyId() external view returns (uint256);
    function Bounty(uint256 bountyId) external view returns (bytes32);
    function tempHolding(address holder, address token) external view returns (uint256);
    function bountyReportId(uint256 bountyId) external view returns (uint256);
}
