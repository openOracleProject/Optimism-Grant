// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/OpenOracleSlim.sol";
import "../../src/OpenOracleBounty2.sol";
import "../../src/GrantFaucet2.sol";
import "../../src/interfaces/IOpenOracle2.sol";
import "../utils/MockERC20.sol";

/**
 * @title OPGrantFaucetTest
 * @notice Tests for the BountyAndPriceRequest contract (GrantFaucet2.sol).
 * @dev Ported from the legacy OpenOracle/openOracleBounty/OPGrantFaucet sketch to the slim,
 *      hash-committed OpenOracleBounty2 + OpenOracleSlim design.
 *
 *      Key differences vs the old test that drive the port:
 *      - `bountyAndPriceRequest(gameId)` now returns a bountyId (NOT a reportId) and creates
 *        ONLY a bounty (no oracle report up front). The oracle report is created later, at
 *        claim time. So we assert bounty.nextBountyId() incremented, faucet.lastBountyId set,
 *        bounty.Bounty(id) != 0 and OP moved from faucet into the bounty contract.
 *      - games(i) is now the 20-field IOpenOracle2.OracleGame tuple; bountyParams(i) is the new
 *        8-field BountyParamSet (creator/editor/timeType/recallOnClaim removed).
 *      - bounty.Bounty(id) returns only a bytes32 hash; struct fields cannot be read back. To
 *        inspect a committed bounty we reconstruct the expected OracleGame+Bounties preimage from
 *        faucet.getCommittedGame(id)/faucet.committedBounty(id) and compare keccak256 hashes.
 *      - recall credits the faucet's tempHolding inside the bounty contract; the faucet pulls it
 *        back via pullTempHolding and the owner withdraws via sweep.
 */
contract OPGrantFaucetTest is Test {
    OpenOracle internal oracle;
    openOracleBounty internal bountyContract;
    BountyAndPriceRequest internal faucet;

    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockERC20 internal opToken;

    address internal owner = address(0x1);
    address internal reporter = address(0x2);
    address internal randomUser = address(0x3);

    // Optimism mainnet addresses (hardcoded in GrantFaucet2)
    address constant WETH_OP = 0x4200000000000000000000000000000000000006;
    address constant USDC_OP = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant OP_TOKEN = 0x4200000000000000000000000000000000000042;

    uint8 constant FLAG_TIME_TYPE = 1 << 0;

    function setUp() public {
        // Deploy oracle and bounty contract
        oracle = new OpenOracle();
        bountyContract = new openOracleBounty(address(oracle));

        // Deploy mock tokens at the hardcoded addresses
        _deployMockAtAddress(WETH_OP, "Wrapped Ether", "WETH", 18);
        _deployMockAtAddress(USDC_OP, "USD Coin", "USDC", 6);
        _deployMockAtAddress(OP_TOKEN, "Optimism", "OP", 18);

        weth = MockERC20(WETH_OP);
        usdc = MockERC20(USDC_OP);
        opToken = MockERC20(OP_TOKEN);

        // Deploy faucet
        faucet = new BountyAndPriceRequest(address(oracle), address(bountyContract), owner);

        // Fund faucet with OP tokens for bounties
        opToken.transfer(address(faucet), 100 ether);

        // Fund faucet with ETH for settler rewards
        vm.deal(address(faucet), 10 ether);

        // Fund reporter with tokens and ETH
        weth.transfer(reporter, 100 ether);
        usdc.transfer(reporter, 1_000_000e6);
        opToken.transfer(reporter, 100 ether);
        vm.deal(reporter, 10 ether);
    }

    function _deployMockAtAddress(address target, string memory name, string memory symbol, uint8 decimals) internal {
        // Deploy mock token at specific address using vm.etch
        MockERC20 mock = new MockERC20(name, symbol);

        // Get the bytecode of the deployed mock
        bytes memory code = address(mock).code;

        // Set the code at target address
        vm.etch(target, code);

        // Use vm.store to set balances directly since constructor won't run
        // For OpenZeppelin ERC20, _balances is at slot 0
        bytes32 slot = keccak256(abi.encode(address(this), uint256(0)));
        vm.store(target, slot, bytes32(uint256(1_000_000 ether)));

        // Set total supply at slot 2
        vm.store(target, bytes32(uint256(2)), bytes32(uint256(1_000_000 ether)));
    }

    // ============ Helpers ============

    /// @dev Reconstructs the committed (OracleGame, Bounties) preimage for a bountyId from the
    ///      faucet's stored copies, and returns the keccak256 hash the bounty contract should hold.
    function _committedHash(uint256 bountyId) internal view returns (bytes32) {
        IOpenOracle2.OracleGame memory og = faucet.getCommittedGame(bountyId);
        openOracleBounty.Bounties memory b = _committedBounty(bountyId);
        return keccak256(abi.encode(og, b));
    }

    /// @dev Reads the faucet's committedBounty(bountyId) public getter into a Bounties struct
    ///      (the bounty contract's own struct type, as required by claim/recall calls).
    function _committedBounty(uint256 bountyId) internal view returns (openOracleBounty.Bounties memory b) {
        (
            uint256 totalAmtDeposited,
            uint256 bountyStartAmt,
            uint256 bountyClaimed,
            uint256 start,
            uint256 roundLength,
            uint256 recallUnlockAt,
            address payable creator,
            address bountyToken,
            uint16 bountyMultiplier,
            uint16 maxRounds,
            bool claimed,
            bool recalled,
            bool storeReportId
        ) = faucet.committedBounty(bountyId);
        b = openOracleBounty.Bounties({
            totalAmtDeposited: totalAmtDeposited,
            bountyStartAmt: bountyStartAmt,
            bountyClaimed: bountyClaimed,
            start: start,
            roundLength: roundLength,
            recallUnlockAt: recallUnlockAt,
            creator: creator,
            bountyToken: bountyToken,
            bountyMultiplier: bountyMultiplier,
            maxRounds: maxRounds,
            claimed: claimed,
            recalled: recalled,
            storeReportId: storeReportId
        });
    }

    function _emptyTiming() internal pure returns (IOpenOracle2.TimingBoundaries memory) {
        return IOpenOracle2.TimingBoundaries(0, 0, 0, 0);
    }

    /// @dev Claims the bounty created for `bountyId` as `claimer`, funding the claimer's oracle
    ///      internal balances for the game's two legs first. Returns the reportId.
    function _claim(address claimer, uint256 bountyId) internal returns (uint256 reportId) {
        IOpenOracle2.OracleGame memory og = faucet.getCommittedGame(bountyId);
        openOracleBounty.Bounties memory b = _committedBounty(bountyId);

        // Fund both legs at the report amounts: token1 = currentAmount1, token2 = any non-zero quote.
        uint128 amount1 = og.currentAmount1;
        uint128 amount2 = og.currentAmount1;

        _fundToken(og.token1, claimer, amount1);
        _fundToken(og.token2, claimer, amount2);

        vm.startPrank(claimer);
        MockERC20(og.token1).approve(address(oracle), type(uint256).max);
        MockERC20(og.token2).approve(address(oracle), type(uint256).max);
        oracle.deposit(og.token1, amount1, claimer);
        oracle.deposit(og.token2, amount2, claimer);
        oracle.approveInternal(address(bountyContract), og.token1, type(uint256).max);
        oracle.approveInternal(address(bountyContract), og.token2, type(uint256).max);
        reportId = bountyContract.claimBounty(bountyId, amount2, og, b, _emptyTiming());
        vm.stopPrank();
    }

    function _fundToken(address token, address to, uint256 amount) internal {
        // The test contract holds 1_000_000 ether of each mock at its hardcoded address.
        if (MockERC20(token).balanceOf(to) < amount) {
            MockERC20(token).transfer(to, amount);
        }
    }

    // ============ Constructor Tests ============

    function testConstructor_SetsImmutables() public view {
        assertEq(address(faucet.oracle()), address(oracle), "Oracle should be set");
        assertEq(address(faucet.bounty()), address(bountyContract), "Bounty contract should be set");
        assertEq(faucet.owner(), owner, "Owner should be set");
    }

    function testConstructor_RevertsZeroOracleAddress() public {
        vm.expectRevert("oracle address cannot be 0");
        new BountyAndPriceRequest(address(0), address(bountyContract), owner);
    }

    function testConstructor_RevertsZeroBountyAddress() public {
        vm.expectRevert("bounty address cannot be 0");
        new BountyAndPriceRequest(address(oracle), address(0), owner);
    }

    function testConstructor_InitializesGameTimers() public view {
        assertEq(faucet.gameTimer(0), 60 * 3, "Game 0 timer should be 3 minutes");
        assertEq(faucet.gameTimer(1), 60 * 10, "Game 1 timer should be 10 minutes");
        assertEq(faucet.gameTimer(2), 60 * 60, "Game 2 timer should be 1 hour");
        assertEq(faucet.gameTimer(3), 60 * 60 * 24, "Game 3 timer should be 24 hours");
    }

    function testConstructor_InitializesBountyForGame() public view {
        assertEq(faucet.bountyForGame(0), 0, "Game 0 uses bounty params 0");
        assertEq(faucet.bountyForGame(1), 0, "Game 1 uses bounty params 0");
        assertEq(faucet.bountyForGame(2), 1, "Game 2 uses bounty params 1");
        assertEq(faucet.bountyForGame(3), 2, "Game 3 uses bounty params 2");
    }

    function testConstructor_InitializesGames() public view {
        // games(i) now returns the 20-field IOpenOracle2.OracleGame tuple.
        (
            uint128 currentAmount1,
            uint128 currentAmount2,
            address currentReporter,
            uint48 reportTimestamp,
            uint48 settlementTimestamp,
            address token1,
            uint48 lastReportOppoTime,
            uint48 settlementTime,
            uint128 escalationHalt,
            address protocolFeeRecipient,
            uint96 settlerReward,
            address token2,
            uint24 numReports,
            uint24 disputeDelay,
            uint24 feePercentage,
            uint16 multiplier,
            address callbackContract,
            uint32 callbackGasLimit,
            uint24 protocolFee,
            uint8 flags
        ) = faucet.games(0);

        // currentAmount1 is the old "exactToken1Report".
        assertEq(currentAmount1, 2000000000000000, "Game 0 currentAmount1");
        assertEq(currentAmount2, 0, "Game 0 currentAmount2");
        assertEq(escalationHalt, 20000000000000000, "Game 0 escalationHalt");
        assertEq(token1, WETH_OP, "Game 0 token1 should be WETH");
        assertEq(token2, USDC_OP, "Game 0 token2 should be USDC");
        assertEq(settlementTime, 10, "Game 0 settlementTime");
        assertEq(multiplier, 125, "Game 0 multiplier");
        assertEq(settlerReward, 500000000000, "Game 0 settlerReward");
        assertEq(protocolFeeRecipient, address(faucet), "Game 0 protocolFeeRecipient");
        // flags bit 0 encodes timeType.
        assertTrue(flags & FLAG_TIME_TYPE != 0, "Game 0 should use timestamp");

        // silence unused warnings
        currentReporter;
        reportTimestamp;
        settlementTimestamp;
        lastReportOppoTime;
        numReports;
        disputeDelay;
        feePercentage;
        callbackContract;
        callbackGasLimit;
        protocolFee;
    }

    function testConstructor_InitializesBountyParams() public view {
        // bountyParams(i) now returns BountyParamSet (creator/editor/timeType/recallOnClaim removed).
        (
            uint256 bountyStartAmt,
            uint16 bountyMultiplier,
            uint16 maxRounds,
            uint256 forwardStartTime,
            address bountyToken,
            uint256 maxAmount,
            uint256 roundLength,
            uint48 recallDelay
        ) = faucet.bountyParams(0);

        assertEq(bountyStartAmt, 1666666660000000, "Bounty 0 startAmt");
        assertEq(bountyMultiplier, 11500, "Bounty 0 multiplier");
        assertEq(maxRounds, 35, "Bounty 0 maxRounds");
        assertEq(forwardStartTime, 10, "Bounty 0 forwardStartTime");
        assertEq(bountyToken, OP_TOKEN, "Bounty 0 token should be OP");
        assertEq(maxAmount, 53333333300000000, "Bounty 0 maxAmount");
        assertEq(roundLength, 6, "Bounty 0 roundLength");
        assertEq(recallDelay, 0, "Bounty 0 recallDelay");
    }

    // ============ bountyAndPriceRequest Tests ============

    function testBountyAndPriceRequest_CreatesReportAndBounty() public {
        uint256 bountyIdBefore = bountyContract.nextBountyId();
        uint256 faucetOPBefore = opToken.balanceOf(address(faucet));
        uint256 bountyContractOPBefore = opToken.balanceOf(address(bountyContract));

        uint256 bountyId = faucet.bountyAndPriceRequest(0);

        // The faucet creates ONLY a bounty (no oracle report yet).
        assertEq(bountyId, bountyIdBefore, "Should return sequential bountyId");
        assertEq(bountyContract.nextBountyId(), bountyIdBefore + 1, "Bounty contract should have new bounty");
        assertEq(faucet.lastBountyId(0), bountyId, "lastBountyId should be set");
        assertEq(oracle.nextReportId(), 1, "No oracle report created yet");

        // Bounty exists (hash stored) and matches the committed preimage.
        assertTrue(bountyContract.Bounty(bountyId) != bytes32(0), "Bounty should exist");
        assertEq(bountyContract.Bounty(bountyId), _committedHash(bountyId), "stored hash matches committed preimage");

        // OP (bounty token) moved from faucet into the bounty contract = bountyParams[0].maxAmount.
        (,,,,, uint256 maxAmount,,) = faucet.bountyParams(0);
        assertEq(opToken.balanceOf(address(faucet)), faucetOPBefore - maxAmount, "Faucet OP decreased by maxAmount");
        assertEq(
            opToken.balanceOf(address(bountyContract)),
            bountyContractOPBefore + maxAmount,
            "Bounty contract holds OP"
        );

        // Committed bounty token is OP.
        openOracleBounty.Bounties memory b = _committedBounty(bountyId);
        assertEq(b.bountyToken, OP_TOKEN, "Bounty token should be OP");
        assertGt(b.maxRounds, 0, "Bounty should exist");
    }

    function testBountyAndPriceRequest_UpdatesLastGameTime() public {
        uint256 timeBefore = faucet.lastGameTime(0);
        assertEq(timeBefore, 0, "lastGameTime should start at 0");

        faucet.bountyAndPriceRequest(0);

        assertEq(faucet.lastGameTime(0), block.timestamp, "lastGameTime should be updated");
    }

    function testBountyAndPriceRequest_EmitsGameCreated() public {
        uint256 expectedBountyId = bountyContract.nextBountyId();

        vm.expectEmit(false, false, false, true, address(faucet));
        emit BountyAndPriceRequest.GameCreated(expectedBountyId, 0);

        faucet.bountyAndPriceRequest(0);
    }

    function testBountyAndPriceRequest_RevertsBadGameId() public {
        // Games 0-5 are valid, 6+ are invalid
        vm.expectRevert(BountyAndPriceRequest.BadGameId.selector);
        faucet.bountyAndPriceRequest(6);

        vm.expectRevert(BountyAndPriceRequest.BadGameId.selector);
        faucet.bountyAndPriceRequest(7);

        vm.expectRevert(BountyAndPriceRequest.BadGameId.selector);
        faucet.bountyAndPriceRequest(255);
    }

    function testBountyAndPriceRequest_EnforcesGameTimer_Game0() public {
        uint256 startTime = block.timestamp;

        // First call should succeed
        faucet.bountyAndPriceRequest(0);

        // Immediate second call should fail
        vm.expectRevert("too early");
        faucet.bountyAndPriceRequest(0);

        // Warp 2 minutes - still too early (game 0 timer is 3 minutes)
        vm.warp(startTime + 2 minutes);
        vm.expectRevert("too early");
        faucet.bountyAndPriceRequest(0);

        // Warp past timer (4 minutes total from start)
        vm.warp(startTime + 4 minutes);
        faucet.bountyAndPriceRequest(0);
    }

    function testBountyAndPriceRequest_EnforcesGameTimer_Game1() public {
        // First call should succeed
        faucet.bountyAndPriceRequest(1);

        // Warp 9 minutes - still too early (game 1 timer is 10 minutes)
        vm.warp(block.timestamp + 9 minutes);
        vm.expectRevert("too early");
        faucet.bountyAndPriceRequest(1);

        // Warp past timer
        vm.warp(block.timestamp + 2 minutes);
        faucet.bountyAndPriceRequest(1);
    }

    function testBountyAndPriceRequest_EnforcesGameTimer_Game2() public {
        // First call should succeed
        faucet.bountyAndPriceRequest(2);

        // Warp 59 minutes - still too early (game 2 timer is 1 hour)
        vm.warp(block.timestamp + 59 minutes);
        vm.expectRevert("too early");
        faucet.bountyAndPriceRequest(2);

        // Warp past timer
        vm.warp(block.timestamp + 2 minutes);
        faucet.bountyAndPriceRequest(2);
    }

    function testBountyAndPriceRequest_EnforcesGameTimer_Game3() public {
        // First call should succeed
        faucet.bountyAndPriceRequest(3);

        // Warp 23 hours - still too early (game 3 timer is 24 hours)
        vm.warp(block.timestamp + 23 hours);
        vm.expectRevert("too early");
        faucet.bountyAndPriceRequest(3);

        // Warp past timer
        vm.warp(block.timestamp + 2 hours);
        faucet.bountyAndPriceRequest(3);
    }

    function testBountyAndPriceRequest_DifferentGamesIndependent() public {
        // Create game 0
        faucet.bountyAndPriceRequest(0);

        // Game 1 should still work (different game)
        faucet.bountyAndPriceRequest(1);

        // Game 0 should still be blocked
        vm.expectRevert("too early");
        faucet.bountyAndPriceRequest(0);
    }

    function testBountyAndPriceRequest_UsesCorrectBountyParams() public {
        // Game 0 and 1 use bountyParams[0]
        uint256 bountyId0 = faucet.bountyAndPriceRequest(0);
        vm.warp(block.timestamp + 10 minutes);
        uint256 bountyId1 = faucet.bountyAndPriceRequest(1);

        openOracleBounty.Bounties memory b0 = _committedBounty(bountyId0);
        openOracleBounty.Bounties memory b1 = _committedBounty(bountyId1);

        // Both should have same bounty params (from bountyParams[0])
        assertEq(b0.bountyStartAmt, b1.bountyStartAmt, "Same bounty start amount");
        assertEq(b0.bountyMultiplier, b1.bountyMultiplier, "Same multiplier");
        assertEq(b0.totalAmtDeposited, b1.totalAmtDeposited, "Same total");

        // Game 2 uses bountyParams[1] - different (higher) start amount
        vm.warp(block.timestamp + 1 hours);
        uint256 bountyId2 = faucet.bountyAndPriceRequest(2);
        openOracleBounty.Bounties memory b2 = _committedBounty(bountyId2);

        assertGt(b2.bountyStartAmt, b0.bountyStartAmt, "Game 2 should have higher bounty start");
    }

    function testBountyAndPriceRequest_AnyoneCanCall() public {
        uint256 startTime = block.timestamp;

        // Owner can call
        vm.prank(owner);
        faucet.bountyAndPriceRequest(0);

        // Warp past game timer (3 minutes)
        vm.warp(startTime + 4 minutes);

        // Random user can call
        vm.prank(randomUser);
        faucet.bountyAndPriceRequest(0);

        // Warp past game timer again
        vm.warp(startTime + 8 minutes);

        // Reporter can call
        vm.prank(reporter);
        faucet.bountyAndPriceRequest(0);
    }

    // ============ sweep Tests ============

    function testSweep_OnlyOwnerCanCall() public {
        vm.prank(randomUser);
        vm.expectRevert("not owner");
        faucet.sweep(address(opToken), 1 ether);

        vm.prank(reporter);
        vm.expectRevert("not owner");
        faucet.sweep(address(opToken), 1 ether);
    }

    function testSweep_ERC20() public {
        uint256 faucetBalBefore = opToken.balanceOf(address(faucet));
        uint256 ownerBalBefore = opToken.balanceOf(owner);
        uint256 sweepAmount = 10 ether;

        vm.prank(owner);
        faucet.sweep(address(opToken), sweepAmount);

        assertEq(opToken.balanceOf(address(faucet)), faucetBalBefore - sweepAmount, "Faucet balance decreased");
        assertEq(opToken.balanceOf(owner), ownerBalBefore + sweepAmount, "Owner balance increased");
    }

    function testSweep_ETH() public {
        uint256 faucetBalBefore = address(faucet).balance;
        uint256 ownerBalBefore = owner.balance;
        uint256 sweepAmount = 1 ether;

        vm.prank(owner);
        faucet.sweep(address(0), sweepAmount);

        assertEq(address(faucet).balance, faucetBalBefore - sweepAmount, "Faucet ETH decreased");
        assertEq(owner.balance, ownerBalBefore + sweepAmount, "Owner ETH increased");
    }

    function testSweep_ETHFailsToRejectingContract() public {
        // Deploy owner as a contract that rejects ETH
        ETHRejecter rejecter = new ETHRejecter();

        // Create new faucet with rejecter as owner
        BountyAndPriceRequest faucetWithRejecter = new BountyAndPriceRequest(
            address(oracle),
            address(bountyContract),
            address(rejecter)
        );
        vm.deal(address(faucetWithRejecter), 10 ether);

        vm.prank(address(rejecter));
        vm.expectRevert("eth transfer failed");
        faucetWithRejecter.sweep(address(0), 1 ether);
    }

    // ============ recallBounties Tests ============

    function testRecallBounties_OnlyOwnerCanCall() public {
        uint256[] memory bountyIds = new uint256[](1);
        bountyIds[0] = 1;

        vm.prank(randomUser);
        vm.expectRevert("not owner");
        faucet.recallBounties(bountyIds);
    }

    function testRecallBounties_RecallsSingleBounty() public {
        // Create a game (which creates a bounty)
        uint256 bountyId = faucet.bountyAndPriceRequest(0);

        // Not recalled yet: committed hash equals current stored hash.
        assertEq(bountyContract.Bounty(bountyId), _committedHash(bountyId), "Bounty not recalled yet");

        uint256[] memory bountyIds = new uint256[](1);
        bountyIds[0] = bountyId;

        // bountyParams[0].recallDelay == 0, so we must warp past creation time.
        vm.warp(block.timestamp + 1);

        vm.prank(owner);
        faucet.recallBounties(bountyIds);

        // Recall credits the faucet's tempHolding inside the bounty contract:
        // OP (totalAmtDeposited) + settlerReward ETH.
        (,,,,, uint256 maxAmount,,) = faucet.bountyParams(0);
        assertEq(bountyContract.tempHolding(address(faucet), OP_TOKEN), maxAmount, "OP recalled to faucet tempHolding");
        (,,,,,,,,, , uint96 settlerReward,,,,,,,,,) = faucet.games(0);
        assertEq(
            bountyContract.tempHolding(address(faucet), address(0)),
            settlerReward,
            "settler reward recalled to faucet tempHolding"
        );

        // Stored hash changed (recalled flag now set), so it differs from the committed (pre-recall) hash.
        assertTrue(bountyContract.Bounty(bountyId) != _committedHash(bountyId), "Bounty hash reflects recall");
    }

    function testRecallBounties_RecallsMultipleBounties() public {
        // Create multiple games
        uint256 bountyId0 = faucet.bountyAndPriceRequest(0);
        uint256 bountyId1 = faucet.bountyAndPriceRequest(1);

        uint256[] memory bountyIds = new uint256[](2);
        bountyIds[0] = bountyId0;
        bountyIds[1] = bountyId1;

        // Warp past recall delays (both 0). Game 0 is timestamp-based and game 1 is block-based
        // (game 1 has no FLAG_TIME_TYPE), so advance both time and block height.
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.prank(owner);
        faucet.recallBounties(bountyIds);

        // Both bounties recalled: their OP totals accumulate in the faucet's tempHolding.
        (,,,,, uint256 maxAmount,,) = faucet.bountyParams(0); // games 0 and 1 both use bountyParams[0]
        assertEq(
            bountyContract.tempHolding(address(faucet), OP_TOKEN),
            maxAmount * 2,
            "Both bounties' OP recalled to faucet tempHolding"
        );

        // Both stored hashes reflect recall.
        assertTrue(bountyContract.Bounty(bountyId0) != _committedHash(bountyId0), "Bounty 0 recalled");
        assertTrue(bountyContract.Bounty(bountyId1) != _committedHash(bountyId1), "Bounty 1 recalled");
    }

    function testRecallBounties_HandlesFailuresGracefully() public {
        // Create a bounty
        uint256 bountyId = faucet.bountyAndPriceRequest(0);

        // Warp past recall delay and recall it directly via the bounty contract first
        // (the faucet is the creator, so it must be the caller).
        vm.warp(block.timestamp + 1);
        IOpenOracle2.OracleGame memory og = faucet.getCommittedGame(bountyId);
        openOracleBounty.Bounties memory b = _committedBounty(bountyId);
        vm.prank(address(faucet));
        bountyContract.recallBounty(bountyId, og, b);

        // Now try to recall again via faucet (stale preimage) + a non-existent id.
        // recallBounties swallows failures in a try/catch, so this should not revert.
        uint256[] memory bountyIds = new uint256[](2);
        bountyIds[0] = bountyId; // Already recalled
        bountyIds[1] = 999; // Non-existent bounty

        vm.prank(owner);
        faucet.recallBounties(bountyIds);
    }

    function testRecallBounties_EmptyArraySucceeds() public {
        uint256[] memory bountyIds = new uint256[](0);

        vm.prank(owner);
        faucet.recallBounties(bountyIds);
    }

    function testRecallBounties_PullTempHoldingAndSweep() public {
        // Full recall flow: recall -> faucet pulls tempHolding back -> owner sweeps.
        uint256 bountyId = faucet.bountyAndPriceRequest(0);

        vm.warp(block.timestamp + 1);

        uint256[] memory bountyIds = new uint256[](1);
        bountyIds[0] = bountyId;
        vm.prank(owner);
        faucet.recallBounties(bountyIds);

        (,,,,, uint256 maxAmount,,) = faucet.bountyParams(0);
        (,,,,,,,,, , uint96 settlerReward,,,,,,,,,) = faucet.games(0);

        uint256 faucetOPBefore = opToken.balanceOf(address(faucet));
        uint256 faucetEthBefore = address(faucet).balance;

        // Pull OP and ETH tempHolding back into the faucet.
        faucet.pullTempHolding(OP_TOKEN);
        faucet.pullTempHolding(address(0));

        assertEq(opToken.balanceOf(address(faucet)), faucetOPBefore + maxAmount, "Faucet pulled OP back");
        assertEq(address(faucet).balance, faucetEthBefore + settlerReward, "Faucet pulled settler reward back");
        assertEq(bountyContract.tempHolding(address(faucet), OP_TOKEN), 0, "OP tempHolding cleared");
        assertEq(bountyContract.tempHolding(address(faucet), address(0)), 0, "ETH tempHolding cleared");

        // Owner sweeps the recovered OP out.
        uint256 ownerOPBefore = opToken.balanceOf(owner);
        vm.prank(owner);
        faucet.sweep(OP_TOKEN, maxAmount);
        assertEq(opToken.balanceOf(owner), ownerOPBefore + maxAmount, "Owner swept recovered OP");
    }

    // ============ receive() Tests ============

    function testReceive_AcceptsETH() public {
        uint256 balBefore = address(faucet).balance;

        vm.deal(randomUser, 1 ether);
        vm.prank(randomUser);
        (bool success,) = address(faucet).call{value: 1 ether}("");

        assertTrue(success, "Should accept ETH");
        assertEq(address(faucet).balance, balBefore + 1 ether, "Balance should increase");
    }

    // ============ Integration Tests ============

    function testIntegration_FullFlow() public {
        // 1. Create a game (creates a bounty; bountyParams[0].forwardStartTime = 10).
        uint256 bountyId = faucet.bountyAndPriceRequest(0);

        // 2. Warp past the bounty's forward start time so it can be claimed.
        vm.warp(block.timestamp + 15);

        openOracleBounty.Bounties memory b = _committedBounty(bountyId);
        uint256 reporterOPBefore = bountyContract.tempHolding(reporter, OP_TOKEN);

        // 3. Reporter claims the bounty (this is what creates the oracle report).
        uint256 reportId = _claim(reporter, bountyId);

        // 4. The oracle report is now created.
        assertTrue(reportId != 0, "Oracle report created on claim");
        assertTrue(oracle.oracleGame(reportId) != bytes32(0), "Oracle game stored");

        // 5. Reporter received the bounty into tempHolding (round 0 == bountyStartAmt).
        uint256 reporterOPAfter = bountyContract.tempHolding(reporter, OP_TOKEN);
        assertEq(reporterOPAfter - reporterOPBefore, b.bountyStartAmt, "Reporter received OP bounty (round 0)");

        // 6. The unclaimed remainder is auto-recalled to the faucet (creator) tempHolding.
        uint256 recalled = b.totalAmtDeposited - b.bountyStartAmt;
        assertEq(bountyContract.tempHolding(address(faucet), OP_TOKEN), recalled, "Remainder auto-recalled to faucet");

        // 7. Reporter pulls the bounty out to its wallet.
        uint256 reporterWalletBefore = opToken.balanceOf(reporter);
        bountyContract.getTempHolding(OP_TOKEN, reporter);
        assertEq(opToken.balanceOf(reporter), reporterWalletBefore + b.bountyStartAmt, "Reporter pulled bounty out");
    }

    function testIntegration_MultipleGamesOverTime() public {
        // Create all 4 base game types.
        uint256 bountyId0 = faucet.bountyAndPriceRequest(0);
        uint256 bountyId1 = faucet.bountyAndPriceRequest(1);
        uint256 bountyId2 = faucet.bountyAndPriceRequest(2);
        uint256 bountyId3 = faucet.bountyAndPriceRequest(3);

        // Verify all bounties were created (committed hash present + maxRounds > 0).
        assertTrue(bountyContract.Bounty(bountyId0) != bytes32(0), "Game 0 bounty exists");
        assertTrue(bountyContract.Bounty(bountyId1) != bytes32(0), "Game 1 bounty exists");
        assertTrue(bountyContract.Bounty(bountyId2) != bytes32(0), "Game 2 bounty exists");
        assertTrue(bountyContract.Bounty(bountyId3) != bytes32(0), "Game 3 bounty exists");
        assertGt(_committedBounty(bountyId0).maxRounds, 0, "Game 0 maxRounds");
        assertGt(_committedBounty(bountyId3).maxRounds, 0, "Game 3 maxRounds");

        // Warp 24+ hours and create another round.
        vm.warp(block.timestamp + 25 hours);

        faucet.bountyAndPriceRequest(0);
        faucet.bountyAndPriceRequest(1);
        faucet.bountyAndPriceRequest(2);
        uint256 bountyId3_2 = faucet.bountyAndPriceRequest(3);

        // bountyIds are sequential and strictly increasing.
        assertGt(bountyId3_2, bountyId3, "New bountyIds should be higher");
        assertEq(faucet.lastBountyId(3), bountyId3_2, "lastBountyId tracks newest");
    }

    // ============ Game 1 block-based timing (flag-drift guard) ============

    /// @dev Game 1 has no FLAG_TIME_TYPE, so its bounty start/round timing is measured in BLOCKS, not
    ///      seconds. This pins that: advancing time alone (vm.warp) never makes the bounty claimable —
    ///      only advancing block height (vm.roll) does. Catches accidental flag drift on games[1].
    function testGame1_BountyTimingIsBlockBased() public {
        uint256 bountyId = faucet.bountyAndPriceRequest(1);
        IOpenOracle2.OracleGame memory og = faucet.getCommittedGame(bountyId);
        openOracleBounty.Bounties memory b = _committedBounty(bountyId);

        // The defining property: game 1 is block-based and its start is a block number.
        assertEq(og.flags & FLAG_TIME_TYPE, 0, "game 1 must be block-based (no FLAG_TIME_TYPE)");
        assertEq(b.start, block.number + 10, "start = block.number + forwardStartTime (blocks)");

        // Fund the claimer's oracle internal balances for both legs (timing-independent).
        uint128 amount1 = og.currentAmount1;
        uint128 amount2 = og.currentAmount1;
        _fundToken(og.token1, reporter, amount1);
        _fundToken(og.token2, reporter, amount2);
        vm.startPrank(reporter);
        MockERC20(og.token1).approve(address(oracle), type(uint256).max);
        MockERC20(og.token2).approve(address(oracle), type(uint256).max);
        oracle.deposit(og.token1, amount1, reporter);
        oracle.deposit(og.token2, amount2, reporter);
        oracle.approveInternal(address(bountyContract), og.token1, type(uint256).max);
        oracle.approveInternal(address(bountyContract), og.token2, type(uint256).max);
        vm.stopPrank();

        // Advancing TIME by a year (but not block height) must NOT make it claimable: still before start block.
        vm.warp(block.timestamp + 365 days);
        vm.prank(reporter);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "start time"));
        bountyContract.claimBounty(bountyId, amount2, og, b, _emptyTiming());

        // Advancing BLOCKS past start makes it claimable.
        vm.roll(b.start + 1);
        vm.prank(reporter);
        uint256 reportId = bountyContract.claimBounty(bountyId, amount2, og, b, _emptyTiming());
        assertTrue(reportId != 0, "claim succeeds once block height passes start");
    }

    // ============ Owner / admin access control ============

    function testSetOpenSwap_OnlyOwner() public {
        vm.prank(randomUser);
        vm.expectRevert("not owner");
        faucet.setOpenSwap(address(0xBEEF));
    }

    function testSetOpenSwap_SetsAddress() public {
        assertEq(faucet.openSwap(), address(0), "openSwap unset initially");
        vm.prank(owner);
        faucet.setOpenSwap(address(0xBEEF));
        assertEq(faucet.openSwap(), address(0xBEEF), "owner sets openSwap");
    }

    function testChangeOwner_OnlyOwner() public {
        vm.prank(randomUser);
        vm.expectRevert("not owner");
        faucet.changeOwner(randomUser);
    }

    function testChangeOwner_TransfersOwnership() public {
        vm.prank(owner);
        faucet.changeOwner(randomUser);
        assertEq(faucet.owner(), randomUser, "ownership transferred");

        // Old owner can no longer call owner-gated functions.
        vm.prank(owner);
        vm.expectRevert("not owner");
        faucet.changeOwner(owner);

        // New owner can.
        vm.prank(randomUser);
        faucet.changeOwner(owner);
        assertEq(faucet.owner(), owner, "new owner can transfer back");
    }

    function testWithdrawOracleBalance_OnlyOwner() public {
        vm.prank(randomUser);
        vm.expectRevert("not owner");
        faucet.withdrawOracleBalance(address(opToken), 1 ether);
    }

    function testWithdrawOracleBalance_SendsToOwner() public {
        // Give the faucet an oracle internal balance of OP, then have the owner withdraw it.
        opToken.approve(address(oracle), type(uint256).max);
        oracle.deposit(address(opToken), 5 ether, address(faucet));

        uint256 ownerBefore = opToken.balanceOf(owner);
        vm.prank(owner);
        uint256 sent = faucet.withdrawOracleBalance(address(opToken), 5 ether);

        assertEq(sent, 5 ether, "withdraws the requested amount");
        assertEq(opToken.balanceOf(owner) - ownerBefore, 5 ether, "owner received the withdrawn OP");
    }
}

// Contract that rejects ETH transfers
contract ETHRejecter {
    // No receive() or fallback(), so ETH transfers will fail
}
