// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle2} from "./interfaces/IOpenOracle2.sol";
import {IOpenOracleBounty2} from "./interfaces/IOpenOracleBounty2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BountyAndPriceRequest
 * @notice For Optimism growth grant.
 */
contract BountyAndPriceRequest is ReentrancyGuard {
    IOpenOracle2 public immutable oracle;
    IOpenOracleBounty2 public immutable bounty;
    address public owner;
    address public immutable USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address public immutable OP = 0x4200000000000000000000000000000000000042;
    address public immutable WETH = 0x4200000000000000000000000000000000000006;

    uint256 public OPWETH;
    uint256 public OPUSDC;
    uint256 public lastPricedUSDCReportId;
    uint256 public lastPricedWETHReportId;

    address public openSwap;
    uint256 public lastOpenSwapClaim;
    uint256 public openSwapTimer = 60;

    using SafeERC20 for IERC20;

    uint8 internal constant FLAG_TIME_TYPE = 1 << 0;
    uint8 internal constant FLAG_TRACK_DISPUTES = 1 << 1;
    uint8 internal constant FLAG_STORE_ALL = 1 << 2;
    uint8 internal constant FLAG_STORE_PRICE = 1 << 3;

    struct BountyParamSet {
        uint256 bountyStartAmt;
        uint16 bountyMultiplier;
        uint16 maxRounds;
        uint256 forwardStartTime;
        address bountyToken;
        uint256 maxAmount;
        uint256 roundLength;
        uint48 recallDelay;
    }

    IOpenOracle2.OracleGame[6] public games;
    uint256[6] public lastGameTime;
    uint256[6] public gameTimer;

    BountyParamSet[4] public bountyParams;

    uint256[6] public lastBountyId;
    uint8[6] public bountyForGame;

    mapping(uint256 => IOpenOracle2.OracleGame) internal committedGame;

    function getCommittedGame(uint256 bountyId) external view returns (IOpenOracle2.OracleGame memory) {
        return committedGame[bountyId];
    }

    mapping(uint256 => IOpenOracleBounty2.Bounties) public committedBounty;

    event GameCreated(uint256 bountyId, uint8 gameId);

    error BadGameId();

    constructor(address _oracle, address _bounty, address _owner) {
        require(_oracle != address(0), "oracle address cannot be 0");
        require(_bounty != address(0), "bounty address cannot be 0");
        oracle = IOpenOracle2(_oracle);
        bounty = IOpenOracleBounty2(_bounty);
        owner = _owner; // will be project multisig when grant is actually received

        gameTimer[0] = 60 * 3;
        gameTimer[1] = 60 * 10;
        gameTimer[2] = 60 * 60;
        gameTimer[3] = 60 * 60 * 24;
        gameTimer[4] = 60 * 60 * 24;
        gameTimer[5] = 60 * 60 * 24;

        bountyForGame[0] = 0;
        bountyForGame[1] = 0;
        bountyForGame[2] = 1;
        bountyForGame[3] = 2;
        bountyForGame[4] = 3;
        bountyForGame[5] = 3;

        games[0] = IOpenOracle2.OracleGame({
            currentAmount1: 2000000000000000,
            currentAmount2: 0,
            currentReporter: address(0),
            reportTimestamp: 0,
            settlementTimestamp: 0,
            token1: 0x4200000000000000000000000000000000000006,
            lastReportOppoTime: 0,
            settlementTime: 10,
            escalationHalt: 20000000000000000,
            protocolFeeRecipient: address(this),
            settlerReward: 500000000000,
            token2: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
            numReports: 0,
            disputeDelay: 2,
            feePercentage: 1,
            multiplier: 125,
            callbackContract: address(0),
            callbackGasLimit: 0,
            protocolFee: 0,
            flags: FLAG_TIME_TYPE | FLAG_STORE_ALL
        });

        games[1] = IOpenOracle2.OracleGame({
            currentAmount1: 20000000,
            currentAmount2: 0,
            currentReporter: address(0),
            reportTimestamp: 0,
            settlementTimestamp: 0,
            token1: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
            lastReportOppoTime: 0,
            settlementTime: 4,
            escalationHalt: 100000000,
            protocolFeeRecipient: address(this),
            settlerReward: 500000000000,
            token2: 0x4200000000000000000000000000000000000006,
            numReports: 0,
            disputeDelay: 0,
            feePercentage: 1,
            multiplier: 110,
            callbackContract: address(0),
            callbackGasLimit: 100000,
            protocolFee: 250,
            flags: FLAG_STORE_ALL
        });

        games[2] = IOpenOracle2.OracleGame({
            currentAmount1: 100000000,
            currentAmount2: 0,
            currentReporter: address(0),
            reportTimestamp: 0,
            settlementTimestamp: 0,
            token1: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
            lastReportOppoTime: 0,
            settlementTime: 600,
            escalationHalt: 1000000000,
            protocolFeeRecipient: address(this),
            settlerReward: 500000000000,
            token2: 0x4200000000000000000000000000000000000006,
            numReports: 0,
            disputeDelay: 0,
            feePercentage: 1,
            multiplier: 150,
            callbackContract: address(0),
            callbackGasLimit: 100000,
            protocolFee: 0,
            flags: FLAG_TIME_TYPE | FLAG_STORE_ALL
        });

        games[3] = IOpenOracle2.OracleGame({
            currentAmount1: 200000000000000000,
            currentAmount2: 0,
            currentReporter: address(0),
            reportTimestamp: 0,
            settlementTimestamp: 0,
            token1: 0x4200000000000000000000000000000000000006,
            lastReportOppoTime: 0,
            settlementTime: 600 * 6 * 4, // 4 hours
            escalationHalt: 1000000000000000000,
            protocolFeeRecipient: address(this),
            settlerReward: 500000000000,
            token2: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
            numReports: 0,
            disputeDelay: 0,
            feePercentage: 1,
            multiplier: 115,
            callbackContract: address(0),
            callbackGasLimit: 100000,
            protocolFee: 0,
            flags: FLAG_TIME_TYPE | FLAG_STORE_ALL
        });

        games[4] = IOpenOracle2.OracleGame({
            currentAmount1: 100000000000000000000,
            currentAmount2: 0,
            currentReporter: address(0),
            reportTimestamp: 0,
            settlementTimestamp: 0,
            token1: 0x4200000000000000000000000000000000000042,
            lastReportOppoTime: 0,
            settlementTime: 60 * 30, // 30 minutes
            escalationHalt: 1000000000000000000000,
            protocolFeeRecipient: address(this),
            settlerReward: 500000000000,
            token2: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
            numReports: 0,
            disputeDelay: 0,
            feePercentage: 1,
            multiplier: 200,
            callbackContract: address(0),
            callbackGasLimit: 0,
            protocolFee: 200000,
            flags: FLAG_TIME_TYPE | FLAG_STORE_ALL | FLAG_STORE_PRICE
        });

        games[5] = IOpenOracle2.OracleGame({
            currentAmount1: 100000000000000000000,
            currentAmount2: 0,
            currentReporter: address(0),
            reportTimestamp: 0,
            settlementTimestamp: 0,
            token1: 0x4200000000000000000000000000000000000042,
            lastReportOppoTime: 0,
            settlementTime: 60 * 30, // 30 minutes
            escalationHalt: 1000000000000000000000,
            protocolFeeRecipient: address(this),
            settlerReward: 500000000000,
            token2: 0x4200000000000000000000000000000000000006,
            numReports: 0,
            disputeDelay: 0,
            feePercentage: 1,
            multiplier: 200,
            callbackContract: address(0),
            callbackGasLimit: 0,
            protocolFee: 200000,
            flags: FLAG_TIME_TYPE | FLAG_STORE_ALL | FLAG_STORE_PRICE
        });

        bountyParams[0] = BountyParamSet({
            bountyStartAmt: 1666666660000000,
            bountyMultiplier: 11500,
            maxRounds: 35,
            forwardStartTime: 10,
            bountyToken: 0x4200000000000000000000000000000000000042,
            maxAmount: 53333333300000000,
            roundLength: 6,
            recallDelay: 0
        });

        bountyParams[1] = BountyParamSet({
            bountyStartAmt: 25866666660000000,
            bountyMultiplier: 12000,
            maxRounds: 35,
            forwardStartTime: 20,
            bountyToken: 0x4200000000000000000000000000000000000042,
            maxAmount: 1257666666600000000,
            roundLength: 6,
            recallDelay: 0
        });

        bountyParams[2] = BountyParamSet({
            bountyStartAmt: 200066666660000000,
            bountyMultiplier: 12000,
            maxRounds: 35,
            forwardStartTime: 20,
            bountyToken: 0x4200000000000000000000000000000000000042,
            maxAmount: 31257666666600000000,
            roundLength: 6,
            recallDelay: 0
        });

        bountyParams[3] = BountyParamSet({
            bountyStartAmt: 100000000000000000,
            bountyMultiplier: 12000,
            maxRounds: 35,
            forwardStartTime: 20,
            bountyToken: 0x4200000000000000000000000000000000000042,
            maxAmount: 10000000000000000000,
            roundLength: 6,
            recallDelay: 0
        });
    }

    function bountyAndPriceRequest(uint8 gameId) external nonReentrant returns (uint256 bountyId) {
        if (gameId >= 6) revert BadGameId();
        BountyParamSet memory bp = bountyParams[bountyForGame[gameId]];
        IOpenOracle2.OracleGame memory og = games[gameId];
        uint256 LastGameTime = lastGameTime[gameId];
        uint256 GameTimer = gameTimer[gameId];

        if (LastGameTime > 0) {
            if (block.timestamp < LastGameTime + GameTimer) revert("too early");
        }
        lastGameTime[gameId] = block.timestamp;

        bool timeType = _hasFlag(og.flags, FLAG_TIME_TYPE);
        uint256 nowT = timeType ? block.timestamp : block.number;

        IOpenOracleBounty2.Bounties memory b = IOpenOracleBounty2.Bounties({
            totalAmtDeposited: bp.maxAmount,
            bountyStartAmt: bp.bountyStartAmt,
            bountyClaimed: 0,
            start: nowT + bp.forwardStartTime,
            roundLength: bp.roundLength,
            recallUnlockAt: nowT + bp.recallDelay,
            creator: payable(address(this)),
            bountyToken: bp.bountyToken,
            bountyMultiplier: bp.bountyMultiplier,
            maxRounds: bp.maxRounds,
            claimed: false,
            recalled: false,
            storeReportId: (gameId == 4 || gameId == 5)
        });

        IERC20(bp.bountyToken).forceApprove(address(bounty), bp.maxAmount);
        bountyId = bounty.createOracleBounty{value: og.settlerReward}(og, b);
        IERC20(bp.bountyToken).forceApprove(address(bounty), 0);

        committedGame[bountyId] = og;
        committedBounty[bountyId] = b;

        lastBountyId[gameId] = bountyId;
        emit GameCreated(bountyId, gameId);
    }

    function updateOPPrices() external nonReentrant {
        _updateOPPrices();
    }

    function _updateOPPrices() internal {
        uint256 usdcReport = bounty.bountyReportId(lastBountyId[4]);
        if (usdcReport != 0 && usdcReport != lastPricedUSDCReportId) {
            uint256 p = oracle.finalPrice(usdcReport);
            if (p != 0) {
                OPUSDC = p;
                lastPricedUSDCReportId = usdcReport;
            }
        }

        uint256 wethReport = bounty.bountyReportId(lastBountyId[5]);
        if (wethReport != 0 && wethReport != lastPricedWETHReportId) {
            uint256 p = oracle.finalPrice(wethReport);
            if (p != 0) {
                OPWETH = p;
                lastPricedWETHReportId = wethReport;
            }
        }
    }

    function openSwapFeeRebate(
        address swapper,
        address sellToken,
        uint256 sellAmt,
        uint256 settlementTime,
        bool timeType,
        uint256 toleranceRange,
        uint256 swapFee,
        uint256 protocolFee
    ) external nonReentrant {
        if (msg.sender != address(openSwap)) revert("not openSwap");

        if (sellToken != address(0) && sellToken != USDC) revert("invalid tokens");
        if (timeType != true) revert("invalid timeType");
        if (settlementTime != 4) revert("invalid settlementTime");
        if (toleranceRange > 50000) revert("slippage too wide");
        if (protocolFee > 500) revert("oracle game fees"); // swapFee is fixed at 0 by openSwap, no longer caller-controllable
        if (sellToken == address(0) && sellAmt > 100000000000000000) revert("selling too much ETH");
        if (sellToken == USDC && sellAmt > 300000000) revert("selling too much USDC");

        _updateOPPrices();

        // calc 0.005% of sellAmt
        uint256 sellAmtRebate = sellAmt / 20000;

        //convert to OP
        if (sellToken == address(0)) {
            sellAmtRebate = sellAmtRebate * OPWETH / 1e30;
        } else {
            sellAmtRebate = sellAmtRebate * OPUSDC / 1e30;
        }

        // A zero-value rebate (e.g. price not yet initialized) must not consume the cooldown.
        if (sellAmtRebate == 0) return;

        lastOpenSwapClaim = block.timestamp;

        IERC20(OP).safeTransfer(swapper, sellAmtRebate);
    }

    function feeRebateEligible() external view returns (bool) {
        if (block.timestamp >= lastOpenSwapClaim + openSwapTimer) {
            return true;
        } else {
            return false;
        }
    }

    function setOpenSwap(address _openSwap) external nonReentrant {
        if (msg.sender != owner) revert("not owner");
        openSwap = _openSwap;
    }

    function sweep(address tokenToGet, uint256 amount) external nonReentrant {
        if (msg.sender != owner) revert("not owner");

        if (tokenToGet != address(0)) {
            IERC20(tokenToGet).safeTransfer(owner, amount);
        } else {
            (bool success,) = payable(owner).call{value: amount}("");
            if (!success) revert("eth transfer failed");
        }
    }

    function pullTempHolding(address token) external nonReentrant {
        bounty.getTempHolding(token, address(this));
    }

    function withdrawOracleBalance(address token, uint256 amount) external nonReentrant returns (uint256 sent) {
        if (msg.sender != owner) revert("not owner");
        sent = oracle.withdrawTo(token, amount, owner);
    }

    function recallBounties(uint256[] calldata bountyIds) external nonReentrant {
        if (msg.sender != owner) revert("not owner");

        for (uint256 i = 0; i < bountyIds.length; i++) {
            uint256 id = bountyIds[i];
            try bounty.recallBounty(id, committedGame[id], committedBounty[id]) {}
            catch {
                // swallow
            }
        }
    }

    function changeOwner(address _owner) external nonReentrant {
        if (msg.sender != owner) revert("not owner");
        owner = _owner;
    }

    function _hasFlag(uint8 flags, uint8 mask) internal pure returns (bool) {
        return flags & mask != 0;
    }

    receive() external payable {}
}
