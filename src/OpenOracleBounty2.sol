// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOpenOracle2} from "./interfaces/IOpenOracle2.sol";

/* *****************************************************
 *      openOracle Initial Report Bounty Contract      *
 ***************************************************** */
contract openOracleBounty is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* immutables */
    IOpenOracle2 public immutable oracle;

    uint256 public nextBountyId = 1;

    uint8 internal constant FLAG_TIME_TYPE = 1 << 0; // = 1
    uint8 internal constant FLAG_TRACK_DISPUTES = 1 << 1; // = 2
    uint8 internal constant FLAG_STORE_ALL = 1 << 2; // = 4
    uint8 internal constant FLAG_STORE_PRICE = 1 << 3; // = 8

    address internal constant ETH_SENTINEL = address(0);

    /* -------- EVENTS -------- */
    event BountyReportSubmitted(uint256 indexed bountyId, Bounties bounty, uint256 bountyPaid);

    event BountyRecalled(
        uint256 indexed bountyId,
        IOpenOracle2.OracleGame oracleGame,
        Bounties bounty,
        uint256 amt,
        address bountyToken,
        uint256 settlerReward
    );

    event BountyCreated(uint256 indexed bountyId, IOpenOracle2.OracleGame oracleGame, Bounties bounty);

    error InvalidInput(string parameter);

    //reportId to bounty
    mapping(uint256 => bytes32) public Bounty;

    //temp holding
    mapping(address => mapping(address => uint256)) public tempHolding;

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
    }

    constructor(address oracle_) {
        require(oracle_ != address(0), "oracle addr 0");
        oracle = IOpenOracle2(oracle_);
    }

    function createOracleBounty(IOpenOracle2.OracleGame calldata oracleGame, Bounties calldata bounty)
        external
        payable
        nonReentrant
        returns (uint256 bountyId)
    {
        uint256 expectedMsgValue = bounty.bountyToken == address(0)
            ? bounty.totalAmtDeposited + oracleGame.settlerReward
            : oracleGame.settlerReward;

        if (
            bounty.maxRounds == 0 || bounty.bountyStartAmt == 0 || bounty.bountyMultiplier == 0
                || bounty.totalAmtDeposited == 0 || bounty.roundLength == 0
        ) revert InvalidInput("amounts cannot = 0");
        if (bounty.maxRounds > 100) revert InvalidInput("too many rounds");
        if (bounty.bountyStartAmt > bounty.totalAmtDeposited) revert InvalidInput("start > max");

        if (_hasFlag(oracleGame.flags, FLAG_TIME_TYPE) ? block.timestamp > bounty.start : block.number > bounty.start) {
            revert InvalidInput("startHeight too low");
        }
        if (bounty.bountyMultiplier < 10001) revert InvalidInput("bountyMultiplier too low");
        if (msg.value != expectedMsgValue) revert InvalidInput("msg.value");

        if (bounty.claimed || bounty.recalled) revert InvalidInput("InvalidBounty");
        if (bounty.creator == address(0)) revert InvalidInput("InvalidBounty");

        if (oracleGame.currentReporter != address(0)) revert InvalidInput("InvalidOracle");
        if (oracleGame.token1 == oracleGame.token2) revert InvalidInput("InvalidOracle");

        if (
            oracleGame.settlementTime == 0 || oracleGame.currentAmount1 == 0
                || oracleGame.disputeDelay >= oracleGame.settlementTime
                || oracleGame.protocolFee + oracleGame.feePercentage > 1e7 || oracleGame.multiplier < 100
                || oracleGame.currentAmount2 != 0 || oracleGame.reportTimestamp != 0 || oracleGame.settlementTimestamp != 0
                || oracleGame.numReports != 0 || oracleGame.lastReportOppoTime != 0
        ) revert InvalidInput("InvalidOracle");

        bountyId = nextBountyId++;

        Bounty[bountyId] = keccak256(abi.encode(oracleGame, bounty));

        if (bounty.bountyToken != address(0)) {
            IERC20(bounty.bountyToken).safeTransferFrom(msg.sender, address(this), bounty.totalAmtDeposited);
        }

        emit BountyCreated(bountyId, oracleGame, bounty);
    }

    function recallBounty(uint256 bountyId, IOpenOracle2.OracleGame calldata oracleGame, Bounties calldata bounty)
        external
        nonReentrant
    {
        bytes32 providedHash = keccak256(abi.encode(oracleGame, bounty));
        if (Bounty[bountyId] != providedHash) revert InvalidInput("InvalidPreimage");

        if (bounty.maxRounds == 0) revert InvalidInput("bounty doesnt exist");
        if (bounty.recalled) revert InvalidInput("bounty already recalled");
        if (bounty.claimed) revert InvalidInput("bounty claimed");
        if (msg.sender != bounty.creator) revert InvalidInput("wrong sender");

        uint256 time = _hasFlag(oracleGame.flags, FLAG_TIME_TYPE) ? block.timestamp : block.number;
        if (time <= bounty.recallUnlockAt) revert InvalidInput("recall delay");

        Bounties memory b = bounty;
        b.recalled = true;
        Bounty[bountyId] = keccak256(abi.encode(oracleGame, b));

        tempHolding[bounty.creator][ETH_SENTINEL] += oracleGame.settlerReward;
        tempHolding[bounty.creator][bounty.bountyToken] += bounty.totalAmtDeposited;
        emit BountyRecalled(
            bountyId, oracleGame, b, bounty.totalAmtDeposited, bounty.bountyToken, oracleGame.settlerReward
        );
    }

    function claimBounty(
        uint256 bountyId,
        uint128 amount2,
        IOpenOracle2.OracleGame calldata oracleGame,
        Bounties calldata bounty,
        IOpenOracle2.TimingBoundaries calldata timing
    ) external nonReentrant returns (uint256 reportId) {
        bytes32 providedHash = keccak256(abi.encode(oracleGame, bounty));
        if (Bounty[bountyId] != providedHash) revert InvalidInput("InvalidPreimage");

        if (bounty.recalled) revert InvalidInput("bounty recalled");
        if (bounty.claimed) revert InvalidInput("bounty claimed");
        if (bounty.maxRounds == 0) revert InvalidInput("bounty doesnt exist");

        address token1 = oracleGame.token1;
        address token2 = oracleGame.token2;
        bool timeType = _hasFlag(oracleGame.flags, FLAG_TIME_TYPE);

        uint256 bountyAmt = calcBounty(
            bounty.start,
            bounty.bountyStartAmt,
            bounty.maxRounds,
            bounty.bountyMultiplier,
            bounty.totalAmtDeposited,
            timeType,
            bounty.roundLength
        );
        uint256 amount = bounty.totalAmtDeposited - bountyAmt;

        IOpenOracle2.OracleGame memory o = oracleGame;
        Bounties memory b = bounty;

        o.currentReporter = msg.sender;
        o.currentAmount2 = amount2;
        b.bountyClaimed = bountyAmt;
        b.claimed = true;
        if (amount > 0) b.recalled = true;

        Bounty[bountyId] = keccak256(abi.encode(o, b));

        tempHolding[msg.sender][bounty.bountyToken] += bountyAmt;

        if (b.recalled) {
            tempHolding[bounty.creator][bounty.bountyToken] += amount;
            emit BountyRecalled(bountyId, o, b, amount, bounty.bountyToken, 0);
        }

        reportId = oracle.report{value: oracleGame.settlerReward}(o, true, true, timing);

        emit BountyReportSubmitted(bountyId, b, bountyAmt);
    }

    /**
     * @notice Withdraws temp holdings for a specific token
     * @param tokenToGet The token address to withdraw tokens for
     */
    function getTempHolding(address tokenToGet, address _to) external nonReentrant {
        uint256 amount = tempHolding[_to][tokenToGet];
        if (amount > 0) {
            if (tokenToGet != address(0)) {
                tempHolding[_to][tokenToGet] = 0;
                _transferTokens(tokenToGet, address(this), _to, amount);
            } else {
                tempHolding[_to][tokenToGet] = 0;
                _sendEth(payable(_to), amount);
            }
        }
    }

    function calcBounty(
        uint256 start,
        uint256 bountyStartAmt,
        uint256 maxRounds,
        uint256 bountyMultiplier,
        uint256 totalAmtDeposited,
        bool timeType,
        uint256 roundLength
    ) internal view returns (uint256) {
        uint256 currentTime = timeType ? block.timestamp : block.number;
        if (currentTime < start) revert InvalidInput("start time");

        uint256 rounds = (currentTime - start) / roundLength;
        if (rounds > maxRounds) {
            rounds = maxRounds;
        }

        uint256 bounty = bountyStartAmt;
        for (uint256 i = 0; i < rounds; i++) {
            bounty = (bounty * bountyMultiplier) / 10000;
        }

        if (bounty > totalAmtDeposited) {
            bounty = totalAmtDeposited;
        }

        return bounty;
    }

    /**
     * @dev Internal function to send ETH to a recipient
     */
    function _sendEth(address payable recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) = recipient.call{value: amount}("");
        if (!success) {
            tempHolding[recipient][address(0)] += amount;
        }
    }

    /**
     * @dev Internal function to handle token transfers.
     */
    function _transferTokens(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return; // Gas optimization: skip zero transfers

        if (from == address(this)) {
            (bool success, bytes memory returndata) =
                token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));

            if (
                success
                    && (
                        (returndata.length > 0 && abi.decode(returndata, (bool)))
                            || (returndata.length == 0 && address(token).code.length > 0)
                    )
            ) {
                return;
            }

            tempHolding[to][token] += amount;
        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }

    receive() external payable {}

    function _hasFlag(uint8 flags, uint8 mask) internal pure returns (bool) {
        return flags & mask != 0;
    }
}
