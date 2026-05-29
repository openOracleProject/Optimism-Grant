// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/OpenOracleSlim.sol";
import "../../src/OpenOracleBounty2.sol";
import "../../src/interfaces/IOpenOracle2.sol";
import "../utils/MockERC20.sol";

// Contract that rejects ETH transfers
contract ETHRejecter {
    // No receive() or fallback(), so ETH transfers will fail
}

// ERC20 with blacklist functionality for testing
contract BlacklistableERC20 is MockERC20 {
    mapping(address => bool) public blacklisted;

    constructor(string memory name, string memory symbol) MockERC20(name, symbol) {}

    function blacklist(address account) external {
        blacklisted[account] = true;
    }

    function unblacklist(address account) external {
        blacklisted[account] = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[msg.sender], "Sender blacklisted");
        require(!blacklisted[to], "Recipient blacklisted");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[from], "Sender blacklisted");
        require(!blacklisted[to], "Recipient blacklisted");
        return super.transferFrom(from, to, amount);
    }
}

/**
 * @title OracleBountyERC20Test
 * @notice Tests for the openOracleBounty contract (ERC20 + ETH bounties).
 * @dev Ported from the legacy OpenOracle/openOracleBounty sketch to the slim,
 *      hash-committed OpenOracleBounty2 + OpenOracleSlim design.
 *
 *      Key differences vs the old test that drive the port:
 *      - Bounties are keyed by a sequential `bountyId`, not by reportId. The
 *        oracle game is created at claim time, not up front.
 *      - Only `keccak256(abi.encode(oracleGame, bounty))` is stored on-chain, so
 *        struct fields cannot be read back. We track expected struct values as
 *        local memory and assert observable effects (balances, tempHolding,
 *        oracle internal balances, events, nextBountyId).
 *      - Claiming a bounty funds the oracle report from the CLAIMER's oracle
 *        internal balance via approveInternal; the bounty payout is credited to
 *        tempHolding[claimer][bountyToken] (not pushed directly).
 *      - Auto-recall of the unclaimed remainder to the creator is now
 *        UNCONDITIONAL (the old recallOnClaim=true behavior).
 */
contract OracleBountyERC20Test is Test {
    OpenOracle internal oracle;
    openOracleBounty internal bountyContract;
    MockERC20 internal token1;
    MockERC20 internal token2;
    MockERC20 internal bountyToken;
    BlacklistableERC20 internal blacklistToken;

    address internal creator = address(0x1111);
    address internal reporter = address(0x3333);
    address internal settler = address(0x4444);
    address internal randomUser = address(0x5555);

    // Oracle params
    uint128 constant INITIAL_LIQUIDITY = 1e18;
    uint48 constant SETTLEMENT_TIME = 300;
    uint24 constant DISPUTE_DELAY = 5;
    uint24 constant FEE_PERCENTAGE = 3000;
    uint24 constant PROTOCOL_FEE = 1000;
    uint16 constant MULTIPLIER = 140;
    uint96 constant SETTLER_REWARD = 0.001 ether;

    // Amount of token2 the claimer quotes for the report.
    uint128 constant AMOUNT2 = 2000e18;

    // Bounty params (ETH bounty)
    uint256 constant BOUNTY_MAX = 1 ether;
    uint256 constant BOUNTY_START = 0.05 ether;
    uint16 constant BOUNTY_MULTIPLIER = 15000; // 1.5x per round
    uint16 constant BOUNTY_MAX_ROUNDS = 10;
    uint256 constant ROUND_LENGTH = 60; // 60 seconds per round

    // Bounty params (ERC20 bounty)
    uint256 constant ERC20_BOUNTY_MAX = 10e18;
    uint256 constant ERC20_BOUNTY_START = 0.5e18;

    uint8 constant FLAG_TIME_TYPE = 1;

    function setUp() public {
        oracle = new OpenOracle();
        bountyContract = new openOracleBounty(address(oracle));

        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");
        bountyToken = new MockERC20("BountyToken", "BNTY");
        blacklistToken = new BlacklistableERC20("BlacklistToken", "BLK");

        // Fund accounts
        token1.transfer(creator, 100e18);
        token1.transfer(reporter, 100e18);
        token2.transfer(creator, 100_000e18);
        token2.transfer(reporter, 100_000e18);
        bountyToken.transfer(creator, 100e18);
        blacklistToken.transfer(creator, 100e18);

        vm.deal(creator, 10 ether);
        vm.deal(reporter, 10 ether);
        vm.deal(settler, 1 ether);

        // Approve bounty contract for creator (for ERC20 bounties)
        vm.startPrank(creator);
        bountyToken.approve(address(bountyContract), type(uint256).max);
        blacklistToken.approve(address(bountyContract), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Helper Functions ============

    /// @dev Builds the canonical fresh OracleGame used at bounty creation.
    ///      currentReporter and currentAmount2 are zero (the contract enforces this).
    function _oracleGame(uint8 flags) internal view returns (IOpenOracle2.OracleGame memory og) {
        og = IOpenOracle2.OracleGame({
            currentAmount1: INITIAL_LIQUIDITY,
            currentAmount2: 0,
            currentReporter: address(0),
            reportTimestamp: 0,
            settlementTimestamp: 0,
            token1: address(token1),
            lastReportOppoTime: 0,
            settlementTime: SETTLEMENT_TIME,
            escalationHalt: INITIAL_LIQUIDITY * 10,
            protocolFeeRecipient: creator,
            settlerReward: SETTLER_REWARD,
            token2: address(token2),
            numReports: 0,
            disputeDelay: DISPUTE_DELAY,
            feePercentage: FEE_PERCENTAGE,
            multiplier: MULTIPLIER,
            callbackContract: address(0),
            callbackGasLimit: 0,
            protocolFee: PROTOCOL_FEE,
            flags: flags
        });
    }

    function _emptyTiming() internal pure returns (IOpenOracle2.TimingBoundaries memory) {
        return IOpenOracle2.TimingBoundaries(0, 0, 0, 0);
    }

    /// @dev Builds a Bounties struct. start defaults to "now" for the given timeType.
    function _bounty(
        address _creator,
        address _bountyToken,
        uint256 totalAmt,
        uint256 startAmt,
        uint256 startDelay,
        uint256 recallDelay,
        bool timeType
    ) internal view returns (openOracleBounty.Bounties memory b) {
        uint256 now_ = timeType ? block.timestamp : block.number;
        b = openOracleBounty.Bounties({
            totalAmtDeposited: totalAmt,
            bountyStartAmt: startAmt,
            bountyClaimed: 0,
            start: now_ + startDelay,
            roundLength: ROUND_LENGTH,
            recallUnlockAt: now_ + recallDelay,
            creator: payable(_creator),
            bountyToken: _bountyToken,
            bountyMultiplier: BOUNTY_MULTIPLIER,
            maxRounds: BOUNTY_MAX_ROUNDS,
            claimed: false,
            recalled: false,
            storeReportId: false
        });
    }

    /// @dev Creates an ETH bounty. Returns the bountyId and the structs needed to reconstruct the preimage.
    function _createEthBounty(address _creator, uint256 recallDelay)
        internal
        returns (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b)
    {
        og = _oracleGame(FLAG_TIME_TYPE);
        b = _bounty(_creator, address(0), BOUNTY_MAX, BOUNTY_START, 0, recallDelay, true);

        vm.prank(creator);
        bountyId = bountyContract.createOracleBounty{value: BOUNTY_MAX + SETTLER_REWARD}(og, b);
    }

    /// @dev Creates an ERC20 bounty with the given token.
    function _createErc20Bounty(address _creator, address _token, uint256 recallDelay)
        internal
        returns (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b)
    {
        og = _oracleGame(FLAG_TIME_TYPE);
        b = _bounty(_creator, _token, ERC20_BOUNTY_MAX, ERC20_BOUNTY_START, 0, recallDelay, true);

        vm.prank(creator);
        bountyId = bountyContract.createOracleBounty{value: SETTLER_REWARD}(og, b);
    }

    /// @dev Funds `claimer`'s oracle internal balances for token1 + token2 and approves the bounty
    ///      contract to spend them, then claims the bounty as `claimer`.
    function _claim(
        address claimer,
        uint256 bountyId,
        IOpenOracle2.OracleGame memory og,
        openOracleBounty.Bounties memory b
    ) internal returns (uint256 reportId) {
        // Fund claimer's oracle internal balance for both report legs.
        vm.startPrank(claimer);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(token1), uint128(INITIAL_LIQUIDITY), claimer);
        oracle.deposit(address(token2), AMOUNT2, claimer);
        oracle.approveInternal(address(bountyContract), address(token1), type(uint256).max);
        oracle.approveInternal(address(bountyContract), address(token2), type(uint256).max);
        reportId = bountyContract.claimBounty(bountyId, AMOUNT2, og, b, _emptyTiming());
        vm.stopPrank();
    }

    /// @dev Mirrors calcBounty: bounty at `rounds` rounds in.
    function _expectedBounty(uint256 startAmt, uint256 totalAmt, uint256 rounds) internal pure returns (uint256) {
        uint256 bounty = startAmt;
        for (uint256 i = 0; i < rounds; i++) {
            bounty = (bounty * BOUNTY_MULTIPLIER) / 10000;
        }
        if (bounty > totalAmt) bounty = totalAmt;
        return bounty;
    }

    /// @dev Reconstructs the post-claim OracleGame + Bounties preimage so recall can be called after a claim.
    function _postClaim(
        IOpenOracle2.OracleGame memory og,
        openOracleBounty.Bounties memory b,
        address claimer,
        uint256 bountyPaid
    ) internal pure returns (IOpenOracle2.OracleGame memory ogP, openOracleBounty.Bounties memory bP) {
        ogP = og;
        ogP.currentReporter = claimer;
        ogP.currentAmount2 = AMOUNT2;

        bP = b;
        bP.bountyClaimed = bountyPaid;
        bP.claimed = true;
        if (b.totalAmtDeposited > bountyPaid) bP.recalled = true;
    }

    // ============ Bounty Creation Tests ============

    function testCreateBounty_ETH() public {
        uint256 creatorBalBefore = creator.balance;

        IOpenOracle2.OracleGame memory og = _oracleGame(FLAG_TIME_TYPE);
        openOracleBounty.Bounties memory b = _bounty(creator, address(0), BOUNTY_MAX, BOUNTY_START, 0, 0, true);

        uint256 idBefore = bountyContract.nextBountyId();

        vm.prank(creator);
        uint256 bountyId = bountyContract.createOracleBounty{value: BOUNTY_MAX + SETTLER_REWARD}(og, b);

        // Creator's ETH decreased by deposit + settler reward (held by bounty contract).
        assertEq(creator.balance, creatorBalBefore - BOUNTY_MAX - SETTLER_REWARD, "Creator ETH should decrease");
        assertEq(address(bountyContract).balance, BOUNTY_MAX + SETTLER_REWARD, "Bounty contract holds funds");

        // bountyId is sequential.
        assertEq(bountyId, idBefore, "bountyId should be sequential");
        assertEq(bountyContract.nextBountyId(), idBefore + 1, "nextBountyId increments");

        // Stored hash matches the supplied preimage (verifiable struct effect).
        assertEq(bountyContract.Bounty(bountyId), keccak256(abi.encode(og, b)), "stored hash matches preimage");

        // Not yet claimed/recalled => recall is still possible (would revert if claimed/recalled).
        // We can confirm via tempHolding being empty.
        assertEq(bountyContract.tempHolding(creator, address(0)), 0, "no tempHolding yet");
    }

    function testCreateBounty_ERC20() public {
        uint256 creatorTokenBefore = bountyToken.balanceOf(creator);

        IOpenOracle2.OracleGame memory og = _oracleGame(FLAG_TIME_TYPE);
        openOracleBounty.Bounties memory b =
            _bounty(creator, address(bountyToken), ERC20_BOUNTY_MAX, ERC20_BOUNTY_START, 0, 0, true);

        vm.prank(creator);
        uint256 bountyId = bountyContract.createOracleBounty{value: SETTLER_REWARD}(og, b);

        // Tokens pulled from creator into the bounty contract.
        assertEq(
            bountyToken.balanceOf(creator), creatorTokenBefore - ERC20_BOUNTY_MAX, "Creator tokens should decrease"
        );
        assertEq(
            bountyToken.balanceOf(address(bountyContract)), ERC20_BOUNTY_MAX, "Bounty contract should hold tokens"
        );

        // settlerReward ETH still pre-funded.
        assertEq(address(bountyContract).balance, SETTLER_REWARD, "settler reward held");

        // Hash records the ERC20 bountyToken.
        assertEq(bountyContract.Bounty(bountyId), keccak256(abi.encode(og, b)), "stored hash matches preimage");
        assertEq(b.bountyToken, address(bountyToken), "bountyToken should be set");
    }

    function testCreateBounty_WithForwardStart() public {
        // Old test used a dedicated forward-start entrypoint + stored forwardStartTime field.
        // Both are removed; forward start is now just b.start in the future. Assert that the
        // bounty cannot be claimed before b.start (calcBounty reverts "start time").
        uint256 forwardTime = 3600;

        IOpenOracle2.OracleGame memory og = _oracleGame(FLAG_TIME_TYPE);
        openOracleBounty.Bounties memory b = _bounty(creator, address(0), BOUNTY_MAX, BOUNTY_START, forwardTime, 0, true);
        uint256 expectedStart = block.timestamp + forwardTime;

        vm.prank(creator);
        uint256 bountyId = bountyContract.createOracleBounty{value: BOUNTY_MAX + SETTLER_REWARD}(og, b);

        assertEq(b.start, expectedStart, "start should be current + forward");
        assertEq(bountyContract.Bounty(bountyId), keccak256(abi.encode(og, b)), "hash committed with forward start");

        // Claiming before start reverts.
        vm.startPrank(reporter);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(token1), uint128(INITIAL_LIQUIDITY), reporter);
        oracle.deposit(address(token2), AMOUNT2, reporter);
        oracle.approveInternal(address(bountyContract), address(token1), type(uint256).max);
        oracle.approveInternal(address(bountyContract), address(token2), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "start time"));
        bountyContract.claimBounty(bountyId, AMOUNT2, og, b, _emptyTiming());
        vm.stopPrank();
    }

    function testCreateBounty_RevertStartGreaterThanMax() public {
        IOpenOracle2.OracleGame memory og = _oracleGame(FLAG_TIME_TYPE);
        openOracleBounty.Bounties memory b =
            _bounty(creator, address(0), BOUNTY_MAX, BOUNTY_MAX + 1, 0, 0, true); // startAmt > total

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "start > max"));
        bountyContract.createOracleBounty{value: BOUNTY_MAX + 1 + SETTLER_REWARD}(og, b);
    }

    function testCreateBounty_RevertMultiplierTooLow() public {
        IOpenOracle2.OracleGame memory og = _oracleGame(FLAG_TIME_TYPE);
        openOracleBounty.Bounties memory b = _bounty(creator, address(0), BOUNTY_MAX, BOUNTY_START, 0, 0, true);
        b.bountyMultiplier = 10000; // must be >= 10001

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "bountyMultiplier too low"));
        bountyContract.createOracleBounty{value: BOUNTY_MAX + SETTLER_REWARD}(og, b);
    }

    function testCreateBounty_RevertZeroAmounts() public {
        IOpenOracle2.OracleGame memory og = _oracleGame(FLAG_TIME_TYPE);
        openOracleBounty.Bounties memory b = _bounty(creator, address(0), BOUNTY_MAX, BOUNTY_START, 0, 0, true);
        b.bountyStartAmt = 0; // zero amount

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "amounts cannot = 0"));
        bountyContract.createOracleBounty{value: BOUNTY_MAX + SETTLER_REWARD}(og, b);
    }

    // ============ Claim Bounty Tests (was submitInitialReport) ============

    function testSubmitInitialReport_ClaimsBounty() public {
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(creator, 0);

        // Bounty at round 0 = BOUNTY_START. Payout is credited to the claimer's tempHolding.
        uint256 reportId = _claim(reporter, bountyId, og, b);

        uint256 expectedBounty = BOUNTY_START;
        assertEq(
            bountyContract.tempHolding(reporter, address(0)), expectedBounty, "Reporter bounty in tempHolding"
        );

        // Report was actually created in the oracle (reportId valid, hash stored).
        assertTrue(reportId != 0, "report created");
        assertTrue(oracle.oracleGame(reportId) != bytes32(0), "oracle game stored");

        // Claimed state is reflected: re-claiming reverts. (post-claim preimage)
        (IOpenOracle2.OracleGame memory ogP, openOracleBounty.Bounties memory bP) =
            _postClaim(og, b, reporter, expectedBounty);
        assertEq(bountyContract.Bounty(bountyId), keccak256(abi.encode(ogP, bP)), "post-claim hash matches");
    }

    function testSubmitInitialReport_BountyEscalatesOverRounds() public {
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(creator, 0);

        // Warp forward 3 rounds.
        vm.warp(block.timestamp + ROUND_LENGTH * 3);

        _claim(reporter, bountyId, og, b);

        uint256 expectedBounty = _expectedBounty(BOUNTY_START, BOUNTY_MAX, 3);
        assertEq(
            bountyContract.tempHolding(reporter, address(0)),
            expectedBounty,
            "Reporter should receive escalated bounty"
        );
    }

    function testSubmitInitialReport_BountyCappedAtMax() public {
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(creator, 0);

        // Warp forward many rounds (bounty should cap at max).
        vm.warp(block.timestamp + ROUND_LENGTH * 20);

        _claim(reporter, bountyId, og, b);

        assertEq(
            bountyContract.tempHolding(reporter, address(0)), BOUNTY_MAX, "Reporter should receive max bounty"
        );
        // Whole amount goes to the claimer; nothing recalled to creator.
        assertEq(bountyContract.tempHolding(creator, address(0)), 0, "nothing recalled when fully claimed");
    }

    function testSubmitInitialReport_RevertBeforeStartTime() public {
        uint256 forwardTime = 3600;

        IOpenOracle2.OracleGame memory og = _oracleGame(FLAG_TIME_TYPE);
        openOracleBounty.Bounties memory b = _bounty(creator, address(0), BOUNTY_MAX, BOUNTY_START, forwardTime, 0, true);

        vm.prank(creator);
        uint256 bountyId = bountyContract.createOracleBounty{value: BOUNTY_MAX + SETTLER_REWARD}(og, b);

        // Try to submit before start time.
        vm.startPrank(reporter);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(token1), uint128(INITIAL_LIQUIDITY), reporter);
        oracle.deposit(address(token2), AMOUNT2, reporter);
        oracle.approveInternal(address(bountyContract), address(token1), type(uint256).max);
        oracle.approveInternal(address(bountyContract), address(token2), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "start time"));
        bountyContract.claimBounty(bountyId, AMOUNT2, og, b, _emptyTiming());
        vm.stopPrank();
    }

    function testSubmitInitialReport_RevertAlreadyClaimed() public {
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(creator, 0);

        _claim(reporter, bountyId, og, b);

        // Try to claim again with the stale (pre-claim) preimage: hash no longer matches.
        vm.prank(reporter);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "InvalidPreimage"));
        bountyContract.claimBounty(bountyId, AMOUNT2, og, b, _emptyTiming());

        // And with the post-claim preimage it reverts because it's already claimed/recalled.
        // (Auto-recall set recalled=true, which the contract checks before the claimed flag.)
        (IOpenOracle2.OracleGame memory ogP, openOracleBounty.Bounties memory bP) =
            _postClaim(og, b, reporter, BOUNTY_START);
        vm.prank(reporter);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "bounty recalled"));
        bountyContract.claimBounty(bountyId, AMOUNT2, ogP, bP, _emptyTiming());
    }

    // ============ Auto-Recall On Claim Tests ============

    function testRecallOnClaim_True_AutoRecallsUnused() public {
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(creator, 0);

        _claim(reporter, bountyId, og, b);

        // Reporter gets bounty at round 0; remainder auto-recalled to creator (unconditional now).
        uint256 bountyPaid = BOUNTY_START;
        uint256 recalled = BOUNTY_MAX - bountyPaid;

        assertEq(bountyContract.tempHolding(reporter, address(0)), bountyPaid, "Reporter bounty in tempHolding");
        assertEq(bountyContract.tempHolding(creator, address(0)), recalled, "Creator recalled remainder in tempHolding");

        // recalled flag is reflected in the post-claim hash.
        (IOpenOracle2.OracleGame memory ogP, openOracleBounty.Bounties memory bP) =
            _postClaim(og, b, reporter, bountyPaid);
        assertTrue(bP.recalled, "post-claim bounty marked recalled");
        assertEq(bountyContract.Bounty(bountyId), keccak256(abi.encode(ogP, bP)), "post-claim hash matches");
    }

    function testRecallOnClaim_ERC20_AutoRecalls() public {
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createErc20Bounty(creator, address(bountyToken), 0);

        _claim(reporter, bountyId, og, b);

        uint256 bountyPaid = ERC20_BOUNTY_START; // round 0
        uint256 recalled = ERC20_BOUNTY_MAX - bountyPaid;

        assertEq(
            bountyContract.tempHolding(reporter, address(bountyToken)),
            bountyPaid,
            "Reporter ERC20 bounty in tempHolding"
        );
        assertEq(
            bountyContract.tempHolding(creator, address(bountyToken)),
            recalled,
            "Creator recalled ERC20 in tempHolding"
        );
    }

    // ============ Manual Recall Tests ============

    function testRecallBounty_BeforeClaim_FullAmount() public {
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(creator, 0);

        // Warp past recall delay.
        vm.warp(block.timestamp + 1);

        vm.prank(creator);
        bountyContract.recallBounty(bountyId, og, b);

        // Creator gets full deposit + settler reward back into tempHolding.
        assertEq(bountyContract.tempHolding(creator, address(0)), BOUNTY_MAX + SETTLER_REWARD, "Creator full recall");

        // recalled flag reflected.
        openOracleBounty.Bounties memory bR = b;
        bR.recalled = true;
        assertEq(bountyContract.Bounty(bountyId), keccak256(abi.encode(og, bR)), "recalled hash matches");
    }

    function testRecallBounty_AfterClaim_PartialAmount() public {
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(creator, 0);

        // Claim bounty first. Auto-recall already returns the remainder to the creator,
        // so a subsequent manual recall must revert (already recalled).
        _claim(reporter, bountyId, og, b);

        uint256 bountyPaid = BOUNTY_START;
        // Creator already received the unclaimed portion via auto-recall.
        assertEq(
            bountyContract.tempHolding(creator, address(0)), BOUNTY_MAX - bountyPaid, "Creator received unclaimed portion"
        );

        (IOpenOracle2.OracleGame memory ogP, openOracleBounty.Bounties memory bP) =
            _postClaim(og, b, reporter, bountyPaid);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "bounty already recalled"));
        bountyContract.recallBounty(bountyId, ogP, bP);
    }

    function testRecallBounty_RevertWrongSender() public {
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(creator, 0);

        // Warp past recall delay so we reach the sender check.
        vm.warp(block.timestamp + 1);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "wrong sender"));
        bountyContract.recallBounty(bountyId, og, b);
    }

    function testRecallBounty_RevertAlreadyRecalled() public {
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(creator, 0);

        vm.warp(block.timestamp + 1);

        vm.prank(creator);
        bountyContract.recallBounty(bountyId, og, b);

        openOracleBounty.Bounties memory bR = b;
        bR.recalled = true;

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "bounty already recalled"));
        bountyContract.recallBounty(bountyId, og, bR);
    }

    function testRecallBounty_RevertAfterRecallOnClaim() public {
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(creator, 0);

        // Claim auto-recalls the remainder.
        _claim(reporter, bountyId, og, b);

        (IOpenOracle2.OracleGame memory ogP, openOracleBounty.Bounties memory bP) =
            _postClaim(og, b, reporter, BOUNTY_START);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "bounty already recalled"));
        bountyContract.recallBounty(bountyId, ogP, bP);
    }

    // ============ Edge Case Tests ============

    function testSubmitInitialReport_RevertBountyRecalled() public {
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(creator, 0);

        // Warp past recall delay then recall bounty.
        vm.warp(block.timestamp + 1);
        vm.prank(creator);
        bountyContract.recallBounty(bountyId, og, b);

        openOracleBounty.Bounties memory bR = b;
        bR.recalled = true;

        // Try to claim the recalled bounty.
        vm.startPrank(reporter);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(token1), uint128(INITIAL_LIQUIDITY), reporter);
        oracle.deposit(address(token2), AMOUNT2, reporter);
        oracle.approveInternal(address(bountyContract), address(token1), type(uint256).max);
        oracle.approveInternal(address(bountyContract), address(token2), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "bounty recalled"));
        bountyContract.claimBounty(bountyId, AMOUNT2, og, bR, _emptyTiming());
        vm.stopPrank();
    }

    // ============ TempHolding Tests - ETH ============

    function testTempHolding_ETHRecallToRejecterGoesToTempHolding() public {
        ETHRejecter rejecter = new ETHRejecter();

        // Bounty with rejecter as creator.
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(address(rejecter), 0);

        vm.warp(block.timestamp + 1);

        // Recall — funds accrue in tempHolding for the rejecter.
        vm.prank(address(rejecter));
        bountyContract.recallBounty(bountyId, og, b);

        assertEq(
            bountyContract.tempHolding(address(rejecter), address(0)),
            BOUNTY_MAX + SETTLER_REWARD,
            "Recalled bounty (+reward) should be in tempHolding"
        );
    }

    function testTempHolding_ETHRecallOnClaimToRejecterGoesToTempHolding() public {
        ETHRejecter rejecter = new ETHRejecter();

        // Bounty with rejecter as creator; auto-recall on claim sends remainder to rejecter's tempHolding.
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(address(rejecter), 0);

        _claim(reporter, bountyId, og, b);

        uint256 expectedRecall = BOUNTY_MAX - BOUNTY_START;
        assertEq(
            bountyContract.tempHolding(address(rejecter), address(0)),
            expectedRecall,
            "Recalled amount should be in tempHolding"
        );
    }

    function testTempHolding_GetTempHolding_ETH_Success() public {
        ETHRejecter rejecter = new ETHRejecter();

        // Get funds into tempHolding for the rejecter via recall.
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(address(rejecter), 0);

        vm.warp(block.timestamp + 1);
        vm.prank(address(rejecter));
        bountyContract.recallBounty(bountyId, og, b);

        uint256 held = BOUNTY_MAX + SETTLER_REWARD;
        assertEq(bountyContract.tempHolding(address(rejecter), address(0)), held, "Should be in tempHolding");

        // getTempHolding pushes to _to. Since _to is the rejecter (still can't receive ETH),
        // it falls back and stays in tempHolding.
        vm.prank(randomUser);
        bountyContract.getTempHolding(address(0), address(rejecter));

        assertEq(
            bountyContract.tempHolding(address(rejecter), address(0)),
            held,
            "Still in tempHolding since rejecter cant receive"
        );
    }

    function testTempHolding_GetTempHolding_ETH_ToEOA() public {
        // getTempHolding with zero amount is a no-op.
        uint256 balBefore = creator.balance;
        bountyContract.getTempHolding(address(0), creator);
        assertEq(creator.balance, balBefore, "No change when tempHolding is 0");
    }

    function testTempHolding_ZeroAmountIsNoOp() public {
        uint256 balBefore = creator.balance;
        uint256 tokenBalBefore = bountyToken.balanceOf(creator);

        bountyContract.getTempHolding(address(0), creator);
        bountyContract.getTempHolding(address(bountyToken), creator);

        assertEq(creator.balance, balBefore, "ETH balance unchanged");
        assertEq(bountyToken.balanceOf(creator), tokenBalBefore, "Token balance unchanged");
    }

    // ============ TempHolding Tests - ERC20 ============

    function testTempHolding_ERC20RecallOnClaimToBlacklistedGoesToTempHolding() public {
        // Bounty with creator that will be blacklisted, ERC20 (blacklist) token.
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createErc20Bounty(creator, address(blacklistToken), 0);

        // Blacklist creator AFTER bounty creation.
        blacklistToken.blacklist(creator);

        uint256 creatorTokenBefore = blacklistToken.balanceOf(creator);

        // Claim auto-recalls remainder to creator. But auto-recall only credits tempHolding;
        // tokens are not pushed at claim time, so creator's balance is unchanged and the
        // recalled amount sits in tempHolding (the push happens at getTempHolding).
        _claim(reporter, bountyId, og, b);

        assertEq(blacklistToken.balanceOf(creator), creatorTokenBefore, "Creator should not receive tokens at claim");

        uint256 expectedRecall = ERC20_BOUNTY_MAX - ERC20_BOUNTY_START;
        assertEq(
            bountyContract.tempHolding(creator, address(blacklistToken)),
            expectedRecall,
            "Recalled tokens should be in tempHolding"
        );

        // While blacklisted, getTempHolding fails the push and re-credits tempHolding.
        bountyContract.getTempHolding(address(blacklistToken), creator);
        assertEq(blacklistToken.balanceOf(creator), creatorTokenBefore, "Still cannot receive while blacklisted");
        assertEq(
            bountyContract.tempHolding(creator, address(blacklistToken)),
            expectedRecall,
            "Recalled tokens remain in tempHolding"
        );
    }

    function testTempHolding_GetTempHolding_ERC20_AfterUnblacklist() public {
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createErc20Bounty(creator, address(blacklistToken), 0);
        blacklistToken.blacklist(creator);

        _claim(reporter, bountyId, og, b);

        uint256 expectedRecall = ERC20_BOUNTY_MAX - ERC20_BOUNTY_START;
        assertEq(bountyContract.tempHolding(creator, address(blacklistToken)), expectedRecall, "in tempHolding");

        // Unblacklist creator.
        blacklistToken.unblacklist(creator);

        uint256 creatorTokenBefore = blacklistToken.balanceOf(creator);

        bountyContract.getTempHolding(address(blacklistToken), creator);

        assertEq(
            blacklistToken.balanceOf(creator),
            creatorTokenBefore + expectedRecall,
            "Creator should receive tokens after unblacklist"
        );
        assertEq(bountyContract.tempHolding(creator, address(blacklistToken)), 0, "tempHolding should be cleared");
    }

    function testTempHolding_MultipleFailedTransfersAccumulate() public {
        ETHRejecter rejecter = new ETHRejecter();

        // First bounty with rejecter as creator.
        (uint256 bountyId1, IOpenOracle2.OracleGame memory og1, openOracleBounty.Bounties memory b1) =
            _createEthBounty(address(rejecter), 0);

        vm.warp(block.timestamp + 1);
        vm.prank(address(rejecter));
        bountyContract.recallBounty(bountyId1, og1, b1);

        uint256 perRecall = BOUNTY_MAX + SETTLER_REWARD;
        assertEq(
            bountyContract.tempHolding(address(rejecter), address(0)), perRecall, "First recall in tempHolding"
        );

        // Second bounty with rejecter as creator.
        (uint256 bountyId2, IOpenOracle2.OracleGame memory og2, openOracleBounty.Bounties memory b2) =
            _createEthBounty(address(rejecter), 0);

        vm.warp(block.timestamp + 2);
        vm.prank(address(rejecter));
        bountyContract.recallBounty(bountyId2, og2, b2);

        assertEq(
            bountyContract.tempHolding(address(rejecter), address(0)),
            perRecall * 2,
            "Both recalls accumulated in tempHolding"
        );
    }

    function testTempHolding_AnyoneCanCallGetTempHolding() public {
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createErc20Bounty(creator, address(blacklistToken), 0);
        blacklistToken.blacklist(creator);

        _claim(reporter, bountyId, og, b);

        blacklistToken.unblacklist(creator);

        uint256 expectedRecall = ERC20_BOUNTY_MAX - ERC20_BOUNTY_START;
        uint256 creatorTokenBefore = blacklistToken.balanceOf(creator);

        // Random user can call getTempHolding for creator.
        vm.prank(randomUser);
        bountyContract.getTempHolding(address(blacklistToken), creator);

        assertEq(
            blacklistToken.balanceOf(creator), creatorTokenBefore + expectedRecall, "Creator receives tokens"
        );
    }

    function testTempHolding_DoesNotAffectNormalTransfers() public {
        // A successful claim still credits the claimer's bounty into tempHolding (by design),
        // but pulling it out lands the funds with the claimer and clears tempHolding.
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createErc20Bounty(creator, address(bountyToken), 0);

        _claim(reporter, bountyId, og, b);

        uint256 reporterBefore = bountyToken.balanceOf(reporter);
        bountyContract.getTempHolding(address(bountyToken), reporter);

        assertEq(
            bountyToken.balanceOf(reporter), reporterBefore + ERC20_BOUNTY_START, "Reporter pulled bounty out"
        );
        assertEq(bountyContract.tempHolding(reporter, address(bountyToken)), 0, "tempHolding cleared");
    }

    function testTempHolding_ERC20_ReporterReceivesBountyDirectly() public {
        // In the new model the bounty is always parked in tempHolding first; the claimer then
        // pulls it out via getTempHolding. Verify the full amount round-trips to the reporter.
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createErc20Bounty(creator, address(bountyToken), 0);

        _claim(reporter, bountyId, og, b);

        assertEq(
            bountyContract.tempHolding(reporter, address(bountyToken)),
            ERC20_BOUNTY_START,
            "Reporter bounty in tempHolding"
        );

        uint256 reporterBefore = bountyToken.balanceOf(reporter);
        bountyContract.getTempHolding(address(bountyToken), reporter);
        assertEq(bountyToken.balanceOf(reporter), reporterBefore + ERC20_BOUNTY_START, "Reporter received bounty");
    }

    // ============ RecallDelay Tests ============

    function testRecallDelay_BlocksRecallBeforeDelay() public {
        uint256 delay = 3600; // 1 hour

        IOpenOracle2.OracleGame memory og = _oracleGame(FLAG_TIME_TYPE);
        openOracleBounty.Bounties memory b = _bounty(creator, address(0), BOUNTY_MAX, BOUNTY_START, 0, delay, true);

        vm.prank(creator);
        uint256 bountyId = bountyContract.createOracleBounty{value: BOUNTY_MAX + SETTLER_REWARD}(og, b);

        // Immediate recall fails.
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "recall delay"));
        bountyContract.recallBounty(bountyId, og, b);

        // Just before delay ends, still fails.
        vm.warp(block.timestamp + delay - 1);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "recall delay"));
        bountyContract.recallBounty(bountyId, og, b);
    }

    function testRecallDelay_AllowsRecallAfterDelay() public {
        uint256 delay = 3600;

        IOpenOracle2.OracleGame memory og = _oracleGame(FLAG_TIME_TYPE);
        openOracleBounty.Bounties memory b = _bounty(creator, address(0), BOUNTY_MAX, BOUNTY_START, 0, delay, true);

        vm.prank(creator);
        uint256 bountyId = bountyContract.createOracleBounty{value: BOUNTY_MAX + SETTLER_REWARD}(og, b);

        vm.warp(block.timestamp + delay + 1);

        vm.prank(creator);
        bountyContract.recallBounty(bountyId, og, b);

        assertEq(
            bountyContract.tempHolding(creator, address(0)),
            BOUNTY_MAX + SETTLER_REWARD,
            "Creator should receive bounty after delay"
        );
    }

    function testRecallDelay_BypassedAfterClaim() public {
        uint256 delay = 3600;

        IOpenOracle2.OracleGame memory og = _oracleGame(FLAG_TIME_TYPE);
        openOracleBounty.Bounties memory b = _bounty(creator, address(0), BOUNTY_MAX, BOUNTY_START, 0, delay, true);

        vm.prank(creator);
        uint256 bountyId = bountyContract.createOracleBounty{value: BOUNTY_MAX + SETTLER_REWARD}(og, b);

        // Claim auto-recalls the unclaimed portion to the creator even though the recall delay
        // hasn't elapsed (claim path bypasses the delay).
        _claim(reporter, bountyId, og, b);

        uint256 expectedRecall = BOUNTY_MAX - BOUNTY_START;
        assertEq(
            bountyContract.tempHolding(creator, address(0)),
            expectedRecall,
            "Creator should receive unclaimed portion despite delay"
        );
    }

    function testRecallDelay_StoredInStruct() public {
        uint256 delay = 7200; // 2 hours

        uint256 creationTime = block.timestamp;

        IOpenOracle2.OracleGame memory og = _oracleGame(FLAG_TIME_TYPE);
        openOracleBounty.Bounties memory b = _bounty(creator, address(0), BOUNTY_MAX, BOUNTY_START, 0, delay, true);

        vm.prank(creator);
        uint256 bountyId = bountyContract.createOracleBounty{value: BOUNTY_MAX + SETTLER_REWARD}(og, b);

        // recallUnlockAt is committed in the hash; assert the computed value and that recall
        // is blocked until exactly that time.
        assertEq(b.recallUnlockAt, creationTime + delay, "recallUnlockAt should be creation time + delay");
        assertEq(bountyContract.Bounty(bountyId), keccak256(abi.encode(og, b)), "hash commits recallUnlockAt");

        vm.warp(creationTime + delay); // == unlock, still blocked (strictly greater required)
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "recall delay"));
        bountyContract.recallBounty(bountyId, og, b);
    }

    function testRecallDelay_ZeroDelayStillRequiresTimeProgress() public {
        // delay = 0 => recallUnlockAt = now at creation. Recall in same block fails (time <= unlock).
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(creator, 0);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "recall delay"));
        bountyContract.recallBounty(bountyId, og, b);

        vm.warp(block.timestamp + 1);
        vm.prank(creator);
        bountyContract.recallBounty(bountyId, og, b);
    }

    function testRecallDelay_BlockBased() public {
        uint256 delay = 100; // 100 blocks

        uint256 creationBlock = block.number;

        // Block-based timing: flags = 0 (FLAG_TIME_TYPE off).
        IOpenOracle2.OracleGame memory og = _oracleGame(0);
        openOracleBounty.Bounties memory b = _bounty(creator, address(0), BOUNTY_MAX, BOUNTY_START, 0, delay, false);

        vm.prank(creator);
        uint256 bountyId = bountyContract.createOracleBounty{value: BOUNTY_MAX + SETTLER_REWARD}(og, b);

        assertEq(b.recallUnlockAt, creationBlock + delay, "recallUnlockAt should be creation block + delay");

        // Roll 50 blocks - still before delay.
        vm.roll(block.number + 50);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "recall delay"));
        bountyContract.recallBounty(bountyId, og, b);

        // Roll past delay.
        vm.roll(block.number + 51);
        vm.prank(creator);
        bountyContract.recallBounty(bountyId, og, b);
    }

    // ============ storeReportId unit coverage ============

    function testStoreReportId_True_RecordsCreatedReportId() public {
        IOpenOracle2.OracleGame memory og = _oracleGame(FLAG_TIME_TYPE);
        openOracleBounty.Bounties memory b = _bounty(creator, address(0), BOUNTY_MAX, BOUNTY_START, 0, 0, true);
        b.storeReportId = true;

        vm.prank(creator);
        uint256 bountyId = bountyContract.createOracleBounty{value: BOUNTY_MAX + SETTLER_REWARD}(og, b);

        // Nothing recorded until the bounty is claimed (and the oracle report is created).
        assertEq(bountyContract.bountyReportId(bountyId), 0, "no report id stored before claim");

        uint256 expectedReportId = oracle.nextReportId();
        uint256 reportId = _claim(reporter, bountyId, og, b);

        // The id the claim created, the id the bounty stored, and the live oracle report all agree.
        assertEq(reportId, expectedReportId, "claim returns the created oracle report id");
        assertEq(bountyContract.bountyReportId(bountyId), reportId, "storeReportId=true records the created report id");
        assertTrue(oracle.oracleGame(reportId) != bytes32(0), "oracle report actually exists for the stored id");
    }

    function testStoreReportId_False_LeavesZero() public {
        // _createEthBounty builds the bounty with storeReportId = false.
        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(creator, 0);

        uint256 reportId = _claim(reporter, bountyId, og, b);

        assertTrue(reportId != 0, "oracle report was still created");
        assertEq(bountyContract.bountyReportId(bountyId), 0, "storeReportId=false leaves bountyReportId at 0");
    }

    // ============ Claimer funds only its own report (currentReporter = msg.sender) ============

    /// @dev Regression for the old "anyone can spend a reporter's allowance" shape. claimBounty forces
    ///      currentReporter = msg.sender, so the oracle report can only be funded from the CALLER's internal
    ///      balance — never from a third party who happened to approve the bounty contract internally.
    function testClaim_CannotSpendOtherUsersInternalBalance() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        token1.transfer(alice, 100e18);
        token2.transfer(alice, 100_000e18);

        (uint256 bountyId, IOpenOracle2.OracleGame memory og, openOracleBounty.Bounties memory b) =
            _createEthBounty(creator, 0);

        // Alice funds her oracle internal balance and approves the bounty contract to spend it.
        vm.startPrank(alice);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(token1), uint128(INITIAL_LIQUIDITY), alice);
        oracle.deposit(address(token2), AMOUNT2, alice);
        oracle.approveInternal(address(bountyContract), address(token1), type(uint256).max);
        oracle.approveInternal(address(bountyContract), address(token2), type(uint256).max);
        vm.stopPrank();

        uint256 aliceTok1Before = oracle.tokenHolder(alice, address(token1));
        uint256 aliceTok2Before = oracle.tokenHolder(alice, address(token2));

        // Bob has no internal balance of his own. Because the claim's reporter is forced to msg.sender (Bob),
        // the oracle report can only draw from Bob's balance, so it reverts — Alice's funds are unreachable.
        vm.prank(bob);
        vm.expectRevert(); // Errors.InsufficientInternalBalance from the oracle's report funding
        bountyContract.claimBounty(bountyId, AMOUNT2, og, b, _emptyTiming());

        // Alice's internal balances are completely untouched.
        assertEq(oracle.tokenHolder(alice, address(token1)), aliceTok1Before, "Alice token1 internal balance untouched");
        assertEq(oracle.tokenHolder(alice, address(token2)), aliceTok2Before, "Alice token2 internal balance untouched");
    }
}
