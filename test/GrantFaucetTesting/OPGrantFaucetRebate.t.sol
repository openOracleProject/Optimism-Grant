// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/OpenOracleSlim.sol";
import "../../src/OpenOracleBounty2.sol";
import "../../src/GrantFaucet2.sol";
import {openSwapV2Optimism as openSwapV2} from "../../src/OpenSwapOptimism.sol";
import "../../src/interfaces/IOpenOracle2.sol";
import "../utils/MockERC20.sol";

/**
 * @title OPGrantFaucetRebateTest
 * @notice Full swap-flow port of the OP rebate tests.
 * @dev Ported from the legacy OpenOracle/openSwapOPGrant/oracleBountyERC20_sketch design to the
 *      slim, hash-committed OpenOracleSlim + OpenOracleBounty2 + GrantFaucet2 + openSwapV2Optimism
 *      design.
 *
 *      The big change: the OLD test cheated by (a) calling grantFaucet.openSwapFeeRebate(...)
 *      directly with a vm.prank'd dummy address, and (b) vm.store-ing OP prices into faucet
 *      storage. BOTH are banned here.
 *
 *      - The rebate is now driven ONLY through a REAL swap: propose -> matchSwap -> execute on
 *        openSwapV2Optimism. execute() itself calls rebateDistributor.openSwapFeeRebate(...) inside
 *        a try/catch when feeRebateEligible() is true. The rebate is therefore OBSERVED via the
 *        swapper's OP balance change after a successful swap. openSwapFeeRebate is never called
 *        directly except in the single access-control test (the "not openSwap" guard is
 *        unreachable through a real swap).
 *      - OP prices are seeded ONLY through the real pull flow: bountyAndPriceRequest(4 or 5) ->
 *        claimBounty -> warp past settlementTime -> oracle.settle(...) -> updateOPPrices().
 *
 *      Rebate math (GrantFaucet2.openSwapFeeRebate): rebate = sellAmt/20000 * OPprice / 1e30,
 *      where OPprice (OPWETH for ETH sells, OPUSDC for USDC sells) is the oracle finalPrice =
 *      currentAmount1 * 1e30 / currentAmount2 of the settled game-5 / game-4 report.
 *
 *      Prices settled on (via the real game flow):
 *        - Game 5 (OP/WETH): claimer quotes 100 OP = 0.01 WETH  -> OPWETH  = 100e18 * 1e30 / 1e16 = 1e34
 *        - Game 4 (OP/USDC): claimer quotes 100 OP = 30 USDC    -> OPUSDC  = 100e18 * 1e30 / 30e6 = 1e50/3e7
 *
 *      Sample expected rebate (ETH sell of 0.1 ETH at OPWETH = 1e34):
 *        sellAmt/20000 = 1e17/20000 = 5e12; 5e12 * 1e34 / 1e30 = 5e16 = 0.05 OP.
 */
contract OPGrantFaucetRebateTest is Test {
    OpenOracle internal oracle;
    openOracleBounty internal bountyContract;
    BountyAndPriceRequest internal grantFaucet;
    openSwapV2 internal swapContract;

    // Optimism mainnet addresses (mocked / hardcoded in GrantFaucet2)
    address constant OP = 0x4200000000000000000000000000000000000042;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    address internal owner = address(0x1);
    address internal swapper = address(0x1001);
    address internal matcher = address(0x1002);
    address internal reporter = address(0x1004);
    address internal settler = address(0x1005);
    address internal executor = address(0x1006);

    uint8 constant FLAG_TIME_TYPE = 1 << 0;

    // ── Swap defaults (rebate-eligible config: settlementTime == 4) ──────
    uint128 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint96 constant SETTLER_REWARD = 0.001 ether;
    uint96 constant MATCHER_GAS_COMP = 0.001 ether;
    uint96 constant EXECUTOR_GAS_COMP = 0.001 ether;
    uint16 constant BLOCKS_PER_SECOND = 500;

    // Captured across the propose/match flow for preimage reconstruction.
    uint48 internal proposeTs;
    uint48 internal reportTs;
    uint48 internal reportBn;

    function setUp() public {
        // Deploy mock tokens at the hardcoded OP addresses.
        _deployMockToken(OP, "Optimism", "OP");
        _deployMockToken(WETH, "Wrapped Ether", "WETH");
        _deployMockToken(USDC, "USD Coin", "USDC");

        // Core contracts.
        oracle = new OpenOracle();
        bountyContract = new openOracleBounty(address(oracle));
        grantFaucet = new BountyAndPriceRequest(address(oracle), address(bountyContract), owner);

        // Swap wired to use the grant faucet as its rebate distributor.
        swapContract = new openSwapV2(address(oracle), address(grantFaucet));

        // Link openSwap to grant faucet.
        vm.prank(owner);
        grantFaucet.setOpenSwap(address(swapContract));

        // Fund grant faucet with OP for rebates + bounties, and ETH for settler rewards.
        deal(OP, address(grantFaucet), 1_000_000e18);
        vm.deal(address(grantFaucet), 10 ether);

        // Fund participants.
        deal(WETH, reporter, 1000e18);
        deal(USDC, reporter, 1_000_000e6);
        deal(OP, reporter, 1_000_000e18);
        deal(WETH, matcher, 1_000_000e18);
        deal(USDC, matcher, 1_000_000e6);
        deal(WETH, swapper, 100e18);
        deal(USDC, swapper, 1_000_000e6);
        vm.deal(swapper, 100 ether);
        vm.deal(matcher, 100 ether);
        vm.deal(reporter, 10 ether);
        vm.deal(settler, 1 ether);
        vm.deal(executor, 1 ether);
    }

    function _deployMockToken(address target, string memory name, string memory symbol) internal {
        MockERC20 mock = new MockERC20(name, symbol);
        vm.etch(target, address(mock).code);
        // Seed this contract with a large balance (constructor didn't run under etch).
        bytes32 slot = keccak256(abi.encode(address(this), uint256(0)));
        vm.store(target, slot, bytes32(uint256(100_000_000e18)));
        vm.store(target, bytes32(uint256(2)), bytes32(uint256(100_000_000e18)));
    }

    // =====================================================================
    //                       PRICE SEEDING (games 4 / 5)
    // =====================================================================

    /// @dev Plays the real game-4 (OP/USDC) or game-5 (OP/WETH) flow:
    ///      bountyAndPriceRequest -> claimBounty (quote amount2) -> warp -> settle -> updateOPPrices.
    ///      Returns the resulting faucet price (OPUSDC for game 4, OPWETH for game 5).
    function _seedPrice(uint8 gameId, uint128 amount2) internal returns (uint256 finalPrice) {
        return _seedPrice(gameId, amount2, true);
    }

    /// @dev When `pushToFaucet` is false, the oracle game is created/claimed/settled but
    ///      grantFaucet.updateOPPrices() is NOT called, so the faucet's OPUSDC/OPWETH stay stale.
    ///      Returns the raw settled oracle price. Used to prove openSwapFeeRebate() refreshes prices itself.
    function _seedPrice(uint8 gameId, uint128 amount2, bool pushToFaucet) internal returns (uint256 finalPrice) {
        require(gameId == 4 || gameId == 5, "only price games");

        uint256 bountyId = grantFaucet.bountyAndPriceRequest(gameId);

        IOpenOracle2.OracleGame memory og = grantFaucet.getCommittedGame(bountyId);
        openOracleBounty.Bounties memory b = _committedBounty(bountyId);

        // Warp past the bounty's forward start time so it can be claimed.
        vm.warp(b.start + 1);

        // Claimer (reporter) funds both oracle report legs from internal balance.
        uint128 amount1 = og.currentAmount1; // 100 OP
        _fund(og.token1, reporter, amount1);
        _fund(og.token2, reporter, amount2);

        vm.startPrank(reporter);
        MockERC20(og.token1).approve(address(oracle), type(uint256).max);
        MockERC20(og.token2).approve(address(oracle), type(uint256).max);
        oracle.deposit(og.token1, amount1, reporter);
        oracle.deposit(og.token2, amount2, reporter);
        _approveInternal(reporter, address(bountyContract), og.token1);
        _approveInternal(reporter, address(bountyContract), og.token2);
        // Capture the report submission ts/bn (oracle.report overrides these) for the settle preimage.
        _claimTs = block.timestamp;
        _claimBn = block.number;
        uint256 reportId = bountyContract.claimBounty(bountyId, amount2, og, b, _emptyTiming());
        vm.stopPrank();

        // Warp past settlement time (games 4/5 settlementTime = 30 minutes) and settle.
        vm.warp(block.timestamp + 60 * 30 + 1);
        vm.roll(block.number + 1000);

        IOpenOracle2.OracleGame memory ogReport = _claimedReportGame(og, reporter, amount2);
        IOpenOracle2.PreimageHelper memory ph = IOpenOracle2.PreimageHelper({
            reportId: reportId,
            creator: address(bountyContract),
            blockTimestamp: _claimTs,
            blockNumber: _claimBn
        });

        vm.prank(settler);
        IOpenOracle2(address(oracle)).settle(reportId, ogReport, ph);

        if (pushToFaucet) {
            grantFaucet.updateOPPrices();
            finalPrice = gameId == 4 ? grantFaucet.OPUSDC() : grantFaucet.OPWETH();
            assertEq(oracle.finalPrice(reportId), finalPrice, "faucet price tracks oracle finalPrice");
        } else {
            // Settle only; leave the faucet price stale on purpose.
            finalPrice = oracle.finalPrice(reportId);
        }
    }

    // Captured during claim (report submission) for the settle preimage.
    uint256 internal _claimTs;
    uint256 internal _claimBn;

    /// @dev Reconstructs the OracleGame as stored by oracle.report() inside claimBounty.
    ///      The bounty contract calls report with currentReporter=claimer, currentAmount2=amount2,
    ///      and the oracle overrides reportTimestamp / lastReportOppoTime at report time.
    function _claimedReportGame(IOpenOracle2.OracleGame memory og, address claimer, uint128 amount2)
        internal
        view
        returns (IOpenOracle2.OracleGame memory r)
    {
        r = og;
        r.currentReporter = claimer;
        r.currentAmount2 = amount2;
        r.reportTimestamp = uint48(_claimTs);
        r.lastReportOppoTime = uint48(_claimBn);
    }

    // =====================================================================
    //                       SWAP FLOW (rebate driver)
    // =====================================================================

    struct SwapConfig {
        address sellToken; // address(0) for ETH or USDC
        uint128 sellAmt;
        address buyToken;
        uint48 settlementTime;
        uint24 disputeDelay;
        uint24 toleranceRange;
        uint24 protocolFee;
        // oracle-game economics (token1 == sellToken so initialLiquidity is in sellToken units)
        uint128 initialLiquidity;
        uint128 amount2; // matcher's buyToken quote
        uint232 priceTolerated; // == initialLiquidity * 1e30 / amount2
    }

    /// @dev Default rebate-eligible swap config: ETH sell, settlementTime 4, tolerance/fee within caps.
    ///      initialLiquidity == sellAmt keeps amounts in the sell token's own decimals.
    function _ethSwapConfig(uint128 sellAmt) internal pure returns (SwapConfig memory c) {
        c = SwapConfig({
            sellToken: address(0),
            sellAmt: sellAmt,
            buyToken: WETH,
            settlementTime: 4,
            disputeDelay: 1,
            toleranceRange: 50000,
            protocolFee: 0,
            initialLiquidity: sellAmt,
            amount2: 2000e18,
            priceTolerated: uint232((uint256(sellAmt) * 1e30) / 2000e18)
        });
    }

    function _usdcSwapConfig(uint128 sellAmt) internal pure returns (SwapConfig memory c) {
        c = SwapConfig({
            sellToken: USDC,
            sellAmt: sellAmt,
            buyToken: WETH,
            settlementTime: 4,
            disputeDelay: 1,
            toleranceRange: 50000,
            protocolFee: 0,
            initialLiquidity: sellAmt,
            amount2: 2000e18,
            priceTolerated: uint232((uint256(sellAmt) * 1e30) / 2000e18)
        });
    }

    /// @dev Runs a full propose -> match -> settle -> execute swap. Returns the swapper's OP balance
    ///      delta (the rebate paid, zero if the rebate guard skipped it). Swapper sells from internal
    ///      balance to avoid permit2 signing.
    function _runSwap(SwapConfig memory c) internal returns (uint256 opRebate) {
        uint256 opBefore = MockERC20(OP).balanceOf(swapper);

        // ── swapper funds the sell leg via internal balance ──
        if (c.sellToken == address(0)) {
            vm.startPrank(swapper);
            oracle.deposit{value: c.sellAmt}(address(0), c.sellAmt, swapper);
            _approveInternal(swapper, address(swapContract), address(0));
            vm.stopPrank();
        } else {
            vm.startPrank(swapper);
            MockERC20(c.sellToken).approve(address(oracle), type(uint256).max);
            oracle.deposit(c.sellToken, c.sellAmt, swapper);
            _approveInternal(swapper, address(swapContract), c.sellToken);
            vm.stopPrank();
        }

        // ── matcher funds the buy leg (minFulfillLiquidity) + the oracle game's token1
        //    initialLiquidity (token1 == sellToken), all from internal balance ──
        _fund(c.buyToken, matcher, uint256(c.amount2) + MIN_FULFILL_LIQUIDITY);
        if (c.sellToken != address(0)) _fund(c.sellToken, matcher, c.initialLiquidity);
        vm.startPrank(matcher);
        MockERC20(c.buyToken).approve(address(oracle), type(uint256).max);
        // buyToken internal must cover the oracle game amount2 (report) + minFulfillLiquidity (match transfer).
        oracle.deposit(c.buyToken, uint128(uint256(c.amount2) + MIN_FULFILL_LIQUIDITY), matcher);
        _approveInternal(matcher, address(swapContract), c.buyToken);
        if (c.sellToken == address(0)) {
            oracle.deposit{value: c.initialLiquidity}(address(0), c.initialLiquidity, matcher);
        } else {
            MockERC20(c.sellToken).approve(address(oracle), type(uint256).max);
            oracle.deposit(c.sellToken, c.initialLiquidity, matcher);
        }
        _approveInternal(matcher, address(swapContract), c.sellToken);
        vm.stopPrank();

        // ── propose ──
        (uint256 swapId, uint48 expiration) = _propose(c);

        // ── match ──
        (uint128 reportId, openSwapV2.MatchedSwap memory sPost) = _match(swapId, expiration, c);

        // ── settle (oracle) then execute (swap) ──
        (openSwapV2.ProposedSwap memory sPre, openSwapV2.MatcherPreimage memory m) =
            _buildSwapAndPreimage(c, expiration);
        IOpenOracle2.OracleGame memory og = _buildOracleGameAtReport(sPre, m, c);
        og.protocolFeeRecipient = sPost.feeRecipient; // matches the clone created at match (or address(0))
        IOpenOracle2.PreimageHelper memory ph = IOpenOracle2.PreimageHelper({
            reportId: reportId,
            creator: address(swapContract),
            blockTimestamp: reportTs,
            blockNumber: reportBn
        });

        vm.warp(block.timestamp + c.settlementTime + 1);
        vm.roll(block.number + 2); // ~ (settlementTime+1) * blocksPerSecond / 1000, within tolerance

        vm.prank(settler);
        IOpenOracle2(address(oracle)).settle(reportId, og, ph);

        IOpenOracle2.OracleGame memory ogSettled = og;
        ogSettled.settlementTimestamp = uint48(block.timestamp);

        vm.prank(executor);
        swapContract.execute(swapId, sPost, ogSettled, ph, false);

        // swap must have executed (not refunded): hash deleted.
        assertEq(swapContract.swaps(swapId), bytes32(0), "swap executed (hash deleted)");

        opRebate = MockERC20(OP).balanceOf(swapper) - opBefore;
    }

    function _propose(SwapConfig memory c) internal returns (uint256 swapId, uint48 expiration) {
        uint48 offset = uint48(1 hours);
        proposeTs = uint48(block.timestamp);
        // The contract overrides s.expiration to an absolute timestamp (proposeTs + offset).
        expiration = uint48(block.timestamp) + offset;
        uint256 ethToSend = MATCHER_GAS_COMP + EXECUTOR_GAS_COMP + SETTLER_REWARD;

        openSwapV2.ProposedSwap memory s;
        s.sellAmt = c.sellAmt;
        s.minFulfillLiquidity = MIN_FULFILL_LIQUIDITY;
        s.settlerReward = SETTLER_REWARD;
        s.maxGameTime = uint24(c.settlementTime) * 20;
        s.blocksPerSecond = BLOCKS_PER_SECOND;
        s.buyToken = c.buyToken;
        s.matcherGasComp = MATCHER_GAS_COMP;
        s.sellToken = c.sellToken;
        s.executorGasComp = EXECUTOR_GAS_COMP;
        s.useInternalBalances = true;
        s.expiration = offset; // contract converts to absolute
        s.priceTolerated = c.priceTolerated;
        s.toleranceRange = c.toleranceRange;

        openSwapV2.MatcherPreimage memory m = _matcherPreimage(c);

        openSwapV2.Permit2Params memory permit2 =
            openSwapV2.Permit2Params({nonce: 0, deadline: type(uint256).max, signature: bytes("")});

        vm.prank(swapper);
        swapId = swapContract.propose{value: ethToSend}(s, m, permit2, _minOut(c));
    }

    /// @dev Conservative minOut consistent with propose()'s worstFulfillAmt bound.
    function _minOut(SwapConfig memory c) internal pure returns (uint128) {
        // fulfillAmt at price = c.sellAmt * amount2 / initialLiquidity; pick well below it.
        uint256 fulfill = (uint256(c.sellAmt) * c.amount2) / c.initialLiquidity;
        return uint128(fulfill / 2 == 0 ? 1 : fulfill / 2);
    }

    function _matcherPreimage(SwapConfig memory c) internal pure returns (openSwapV2.MatcherPreimage memory m) {
        m.initialLiquidity = c.initialLiquidity;
        m.escalationHalt = c.initialLiquidity * 2;
        m.settlementTime = c.settlementTime;
        m.disputeDelay = c.disputeDelay;
        m.protocolFee = c.protocolFee;
        m.multiplier = 110;
        m.maxFee = 10000;
        m.startingFee = 10000;
        m.roundLength = 60;
        m.growthRate = 15000;
        m.maxRounds = 10;
    }

    function _match(uint256 swapId, uint48 expiration, SwapConfig memory c)
        internal
        returns (uint128 reportId, openSwapV2.MatchedSwap memory sPost)
    {
        (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m) = _buildSwapAndPreimage(c, expiration);
        IOpenOracle2.TimingBoundaries memory timing = IOpenOracle2.TimingBoundaries(0, 0, 0, 0);

        reportTs = uint48(block.timestamp);
        reportBn = uint48(block.number);
        reportId = uint128(oracle.nextReportId());

        address predictedClone = m.protocolFee > 0
            ? vm.computeCreateAddress(address(swapContract), vm.getNonce(address(swapContract)))
            : address(0);

        vm.prank(matcher);
        swapContract.matchSwap(swapId, c.amount2, s, m, timing);

        sPost = _postMatchSwap(s, reportId, c);
        sPost.feeRecipient = predictedClone;
    }

    function _buildSwapAndPreimage(SwapConfig memory c, uint48 expiration)
        internal
        view
        returns (openSwapV2.ProposedSwap memory s, openSwapV2.MatcherPreimage memory m)
    {
        s.swapper = swapper;
        s.sellAmt = c.sellAmt;
        s.sellToken = c.sellToken;
        s.buyToken = c.buyToken;
        s.minFulfillLiquidity = MIN_FULFILL_LIQUIDITY;
        s.expiration = expiration;
        s.maxGameTime = uint24(c.settlementTime) * 20;
        s.blocksPerSecond = BLOCKS_PER_SECOND;
        s.settlerReward = SETTLER_REWARD;
        s.priceTolerated = c.priceTolerated;
        s.toleranceRange = c.toleranceRange;
        s.matcherGasComp = MATCHER_GAS_COMP;
        s.executorGasComp = EXECUTOR_GAS_COMP;
        s.useInternalBalances = true;

        m = _matcherPreimage(c);
        m.startFulfillFeeIncrease = proposeTs;
    }

    function _postMatchSwap(openSwapV2.ProposedSwap memory s, uint128 reportId, SwapConfig memory c)
        internal
        view
        returns (openSwapV2.MatchedSwap memory sp)
    {
        sp.sellAmt = s.sellAmt;
        sp.minFulfillLiquidity = s.minFulfillLiquidity;
        sp.maxGameTime = s.maxGameTime;
        sp.blocksPerSecond = s.blocksPerSecond;
        sp.buyToken = s.buyToken;
        sp.sellToken = s.sellToken;
        sp.swapper = s.swapper;
        sp.executorGasComp = s.executorGasComp;
        sp.useInternalBalances = s.useInternalBalances;
        sp.priceTolerated = s.priceTolerated;
        sp.toleranceRange = s.toleranceRange;
        sp.matcher = matcher;
        sp.start = reportTs;
        sp.fulfillmentFee = _calcFulfillFee(c);
        sp.reportId = reportId;
    }

    function _calcFulfillFee(SwapConfig memory c) internal view returns (uint24) {
        openSwapV2.MatcherPreimage memory ff = _matcherPreimage(c);
        uint256 timeDelta = (block.timestamp - proposeTs) / ff.roundLength;
        if (timeDelta > ff.maxRounds) timeDelta = ff.maxRounds;
        uint256 currentFee = ff.startingFee;
        for (uint256 i = 0; i < timeDelta; i++) {
            currentFee = (currentFee * ff.growthRate) / 10000;
            if (currentFee >= ff.maxFee) return uint24(ff.maxFee);
        }
        return uint24(currentFee);
    }

    function _buildOracleGameAtReport(
        openSwapV2.ProposedSwap memory s,
        openSwapV2.MatcherPreimage memory m,
        SwapConfig memory c
    ) internal view returns (IOpenOracle2.OracleGame memory) {
        return IOpenOracle2.OracleGame({
            currentAmount1: m.initialLiquidity,
            currentAmount2: c.amount2,
            currentReporter: matcher,
            reportTimestamp: reportTs,
            settlementTimestamp: 0,
            token1: s.sellToken,
            lastReportOppoTime: reportBn,
            settlementTime: m.settlementTime,
            escalationHalt: m.escalationHalt,
            protocolFeeRecipient: address(0),
            settlerReward: uint96(s.settlerReward),
            token2: s.buyToken,
            numReports: 0,
            disputeDelay: m.disputeDelay,
            feePercentage: 0,
            multiplier: m.multiplier,
            callbackContract: address(0),
            callbackGasLimit: 0,
            protocolFee: m.protocolFee,
            flags: 1
        });
    }

    // =====================================================================
    //                            small helpers
    // =====================================================================

    function _emptyTiming() internal pure returns (IOpenOracle2.TimingBoundaries memory) {
        return IOpenOracle2.TimingBoundaries(0, 0, 0, 0);
    }

    /// @dev Sets a max internal allowance only if not already non-zero (oracle rejects re-approve).
    ///      Assumes `who` is the active prank sender.
    function _approveInternal(address who, address spender, address token) internal {
        if (oracle.internalAllowance(who, spender, token) == 0) {
            oracle.approveInternal(spender, token, type(uint256).max);
        }
    }

    function _fund(address token, address to, uint256 amount) internal {
        if (MockERC20(token).balanceOf(to) < amount) {
            MockERC20(token).transfer(to, amount);
        }
    }

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
        ) = grantFaucet.committedBounty(bountyId);
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

    // =====================================================================
    //                          INITIAL STATE TESTS
    // =====================================================================

    function testInitialOPPrices() public view {
        // No price seeded yet -> both zero (prices are now discovered via the oracle, not preset).
        assertEq(grantFaucet.OPWETH(), 0, "OPWETH starts unset");
        assertEq(grantFaucet.OPUSDC(), 0, "OPUSDC starts unset");
    }

    function testFeeRebateEligible_InitiallyFalse_ThenEligibleAfterTimer() public {
        // block.timestamp starts at 1; lastOpenSwapClaim 0, openSwapTimer 60 -> not eligible.
        assertFalse(grantFaucet.feeRebateEligible(), "NOT eligible at timestamp 1");
        vm.warp(60);
        assertTrue(grantFaucet.feeRebateEligible(), "eligible after 60 seconds");
    }

    // =====================================================================
    //                    ORACLE GAME 4 (OP/USDC) TESTS
    // =====================================================================

    function testGame4_CreatesOPUSDCPriceFeed() public {
        uint256 bountyId = grantFaucet.bountyAndPriceRequest(4);
        assertEq(grantFaucet.lastBountyId(4), bountyId, "lastBountyId[4] set");

        IOpenOracle2.OracleGame memory og = grantFaucet.getCommittedGame(bountyId);
        assertEq(og.token1, OP, "token1 should be OP");
        assertEq(og.token2, USDC, "token2 should be USDC");
    }

    function testGame4_SettlesAndUpdatesOPUSDC() public {
        uint256 oldOPUSDC = grantFaucet.OPUSDC();

        // 100 OP = 30 USDC quote.
        uint256 price = _seedPrice(4, 30e6);

        assertNotEq(price, oldOPUSDC, "OPUSDC updated after settlement");
        uint256 expectedPrice = (uint256(100e18) * 1e30) / 30e6;
        assertEq(price, expectedPrice, "OPUSDC matches oracle finalPrice");
    }

    // =====================================================================
    //                    ORACLE GAME 5 (OP/WETH) TESTS
    // =====================================================================

    function testGame5_CreatesOPWETHPriceFeed() public {
        uint256 bountyId = grantFaucet.bountyAndPriceRequest(5);
        assertEq(grantFaucet.lastBountyId(5), bountyId, "lastBountyId[5] set");

        IOpenOracle2.OracleGame memory og = grantFaucet.getCommittedGame(bountyId);
        assertEq(og.token1, OP, "token1 should be OP");
        assertEq(og.token2, WETH, "token2 should be WETH");
    }

    function testGame5_SettlesAndUpdatesOPWETH() public {
        uint256 oldOPWETH = grantFaucet.OPWETH();

        // 100 OP = 0.05 WETH quote.
        uint256 price = _seedPrice(5, 5e16);

        assertNotEq(price, oldOPWETH, "OPWETH updated after settlement");
        uint256 expectedPrice = (uint256(100e18) * 1e30) / 5e16;
        assertEq(price, expectedPrice, "OPWETH matches oracle finalPrice");
    }

    // =====================================================================
    //                   REBATE CALCULATION SANITY TESTS
    // =====================================================================

    function testRebateCalculation_ETHSell_Sanity() public {
        // Seed OPWETH via the real game flow (100 OP = 0.01 WETH -> OPWETH = 1e34).
        uint256 opWeth = _seedPrice(5, 1e16);
        assertEq(opWeth, 1e34, "OPWETH = 1e34");

        // Drive a real 0.1 ETH swap and observe the rebate.
        vm.warp(block.timestamp + 61); // clear cooldown
        uint256 rebate = _runSwap(_ethSwapConfig(0.1 ether));

        uint256 expected = (uint256(0.1 ether) / 20000) * opWeth / 1e30;
        assertEq(rebate, expected, "rebate matches formula");
        assertEq(rebate, 5e16, "0.05 OP for 0.1 ETH swap");
    }

    function testRebateCalculation_USDCSell_Sanity() public {
        // Seed OPUSDC (100 OP = 30 USDC -> OPUSDC = 1e50/3e7).
        uint256 opUsdc = _seedPrice(4, 30e6);

        vm.warp(block.timestamp + 61);
        uint256 rebate = _runSwap(_usdcSwapConfig(300e6));

        uint256 expected = (uint256(300e6) / 20000) * opUsdc / 1e30;
        assertEq(rebate, expected, "rebate matches formula");
    }

    // =====================================================================
    //              openSwapFeeRebate ACCESS CONTROL (direct call)
    // =====================================================================

    function testRebate_OnlyOpenSwapCanCall() public {
        // The msg.sender != openSwap guard cannot be hit through a real swap, so this is the one
        // legitimate direct call: a random address must be rejected.
        vm.prank(swapper);
        vm.expectRevert("not openSwap");
        grantFaucet.openSwapFeeRebate(swapper, address(0), 0.1 ether, 4, true, 50000, 0, 0);
    }

    // =====================================================================
    //         VALIDATION TESTS (reframed: swap succeeds, NO rebate)
    // =====================================================================

    function testRebate_InvalidSellToken_NoRebate() public {
        _seedPrice(5, 1e16); // OPWETH set
        vm.warp(block.timestamp + 61);

        // Sell WETH (neither ETH nor USDC) -> rebate guard rejects, swap still succeeds.
        SwapConfig memory c = _ethSwapConfig(0.1 ether);
        c.sellToken = WETH;
        c.buyToken = USDC;
        uint256 rebate = _runSwap(c);
        assertEq(rebate, 0, "no rebate for invalid sell token");
    }

    function testRebate_InvalidSettlementTime_NoRebate() public {
        _seedPrice(5, 1e16);
        vm.warp(block.timestamp + 61);

        // settlementTime 10 (not 4) -> rebate guard rejects, swap still succeeds.
        SwapConfig memory c = _ethSwapConfig(0.1 ether);
        c.settlementTime = 10;
        uint256 rebate = _runSwap(c);
        assertEq(rebate, 0, "no rebate when settlementTime != 4");
    }

    function testRebate_ToleranceRangeTooWide_NoRebate() public {
        _seedPrice(5, 1e16);
        vm.warp(block.timestamp + 61);

        // toleranceRange 60000 (> 50000) -> rebate guard rejects. Price == priceTolerated so the
        // swap's own slippage check still passes and execute succeeds.
        SwapConfig memory c = _ethSwapConfig(0.1 ether);
        c.toleranceRange = 60000;
        uint256 rebate = _runSwap(c);
        assertEq(rebate, 0, "no rebate when toleranceRange too wide");
    }

    function testRebate_ProtocolFeeTooHigh_NoRebate() public {
        _seedPrice(5, 1e16);
        vm.warp(block.timestamp + 61);

        // protocolFee 600 (> 500) -> rebate guard rejects, swap still succeeds.
        SwapConfig memory c = _ethSwapConfig(0.1 ether);
        c.protocolFee = 600;
        uint256 rebate = _runSwap(c);
        assertEq(rebate, 0, "no rebate when protocolFee too high");
    }

    function testRebate_ETHSellTooMuch_NoRebate() public {
        _seedPrice(5, 1e16);
        vm.warp(block.timestamp + 61);

        // Sell 0.1 ETH + 1 wei (> 1e17 cap) -> rebate guard rejects, swap still succeeds.
        SwapConfig memory c = _ethSwapConfig(uint128(0.1 ether + 1));
        uint256 rebate = _runSwap(c);
        assertEq(rebate, 0, "no rebate when selling too much ETH");
    }

    function testRebate_USDCSellTooMuch_NoRebate() public {
        _seedPrice(4, 30e6);
        vm.warp(block.timestamp + 61);

        // Sell 300 USDC + 1 (> 3e8 cap) -> rebate guard rejects, swap still succeeds.
        SwapConfig memory c = _usdcSwapConfig(uint128(300e6 + 1));
        uint256 rebate = _runSwap(c);
        assertEq(rebate, 0, "no rebate when selling too much USDC");
    }

    // =====================================================================
    //                       SUCCESSFUL REBATE TESTS
    // =====================================================================

    function testRebate_ETHSell_Success() public {
        uint256 opWeth = _seedPrice(5, 1e16); // 1e34
        vm.warp(block.timestamp + 61);

        uint256 rebate = _runSwap(_ethSwapConfig(0.1 ether));

        uint256 expected = (uint256(0.1 ether) / 20000) * opWeth / 1e30;
        assertEq(rebate, expected, "ETH sell rebate matches calc");
        assertGt(rebate, 0, "rebate paid");
    }

    function testRebate_USDCSell_Success() public {
        uint256 opUsdc = _seedPrice(4, 30e6);
        vm.warp(block.timestamp + 61);

        uint256 rebate = _runSwap(_usdcSwapConfig(300e6));

        uint256 expected = (uint256(300e6) / 20000) * opUsdc / 1e30;
        assertEq(rebate, expected, "USDC sell rebate matches calc");
        assertGt(rebate, 0, "rebate paid");
    }

    // =====================================================================
    //                            COOLDOWN TESTS
    // =====================================================================

    function testCooldown_NotEligibleImmediatelyAfterClaim() public {
        _seedPrice(5, 1e16);
        vm.warp(block.timestamp + 61);

        uint256 rebate = _runSwap(_ethSwapConfig(0.1 ether));
        assertGt(rebate, 0, "first rebate paid");

        // The successful rebate set lastOpenSwapClaim = now -> not eligible immediately.
        assertFalse(grantFaucet.feeRebateEligible(), "not eligible right after claim");
    }

    function testCooldown_EligibleAfter60Seconds() public {
        _seedPrice(5, 1e16);
        vm.warp(block.timestamp + 61);

        _runSwap(_ethSwapConfig(0.1 ether));
        assertFalse(grantFaucet.feeRebateEligible(), "on cooldown");

        // Second swap within 60s -> swap succeeds but no additional OP rebate.
        vm.warp(block.timestamp + 30);
        uint256 rebate2 = _runSwap(_ethSwapConfig(0.1 ether));
        assertEq(rebate2, 0, "no rebate during cooldown");

        // After full cooldown, rebate pays again.
        vm.warp(grantFaucet.lastOpenSwapClaim() + grantFaucet.openSwapTimer() + 1);
        assertTrue(grantFaucet.feeRebateEligible(), "eligible after cooldown");
        uint256 rebate3 = _runSwap(_ethSwapConfig(0.1 ether));
        assertGt(rebate3, 0, "rebate paid again after cooldown");
    }

    // =====================================================================
    //                  PRICE UPDATE INTEGRATION TEST
    // =====================================================================

    function testRebateWithUpdatedPrices() public {
        // Seed OPWETH via game 5: 100 OP = 0.05 WETH -> OPWETH = 100e18 * 1e30 / 5e16 = 2e33.
        uint256 opWeth = _seedPrice(5, 5e16);
        uint256 expectedPrice = (uint256(100e18) * 1e30) / 5e16;
        assertEq(opWeth, expectedPrice, "OPWETH from settled game");

        vm.warp(block.timestamp + 61);
        uint256 rebate = _runSwap(_ethSwapConfig(0.1 ether));

        uint256 expectedRebate = (uint256(0.1 ether) / 20000) * opWeth / 1e30;
        assertEq(rebate, expectedRebate, "rebate uses updated price");
    }

    // =====================================================================
    //                       MAX REBATE SANITY CHECKS
    // =====================================================================

    function testMaxRebate_ETH_SanityCheck() public {
        // OP ~ $0.30, ETH ~ $3000 -> 1 ETH = 10,000 OP. Seed via game 5: 100 OP = 0.01 WETH.
        uint256 opWeth = _seedPrice(5, 1e16);
        assertEq(opWeth, 1e34, "OPWETH = 1e34 (10,000 OP/ETH)");

        vm.warp(block.timestamp + 61);
        uint256 rebate = _runSwap(_ethSwapConfig(0.1 ether)); // max ETH sell

        // 0.1 ETH * 0.005% = 5e12; * 1e34 / 1e30 = 5e16 = 0.05 OP.
        assertEq(rebate, 5e16, "0.05 OP for max ETH swap");
    }

    function testMaxRebate_USDC_SanityCheck() public {
        // OP ~ $0.30, USDC $1 -> 100 OP = 30 USDC. Seed via game 4.
        uint256 opUsdc = _seedPrice(4, 30e6);

        vm.warp(block.timestamp + 61);
        uint256 rebate = _runSwap(_usdcSwapConfig(300e6)); // max USDC sell

        // 300 USDC * 0.005% = 15000 (6-dec); * OPUSDC / 1e30 ~ 0.05 OP.
        assertApproxEqRel(rebate, 5e16, 0.01e18, "~0.05 OP for max USDC swap");
    }

    // =====================================================================
    //              END-TO-END ORACLE-GAME PRICE DISCOVERY
    // =====================================================================

    function testEndToEnd_OracleGamePricing_ETH() public {
        // Price comes purely from a settled game-5 report.
        uint256 oracleOPWETH = _seedPrice(5, 1e16);
        uint256 expectedPrice = (uint256(100e18) * 1e30) / 1e16;
        assertEq(oracleOPWETH, expectedPrice, "OPWETH from oracle");
        assertEq(oracleOPWETH, 1e34, "10,000 OP per ETH");

        vm.warp(block.timestamp + 61);
        uint256 rebate = _runSwap(_ethSwapConfig(0.1 ether));

        assertEq(rebate, 5e16, "0.05 OP from oracle-derived price");
        uint256 rebateUSDCents = (rebate * 30) / 1e18; // OP @ $0.30
        assertTrue(rebateUSDCents < 10, "rebate < 10 cents");
        assertTrue(rebateUSDCents >= 1, "rebate >= 1 cent");
    }

    function testEndToEnd_OracleGamePricing_USDC() public {
        uint256 oracleOPUSDC = _seedPrice(4, 30e6);
        uint256 expectedPrice = (uint256(100e18) * 1e30) / 30e6;
        assertEq(oracleOPUSDC, expectedPrice, "OPUSDC from oracle");

        vm.warp(block.timestamp + 61);
        uint256 rebate = _runSwap(_usdcSwapConfig(300e6));

        uint256 expectedRebate = (uint256(300e6) / 20000) * oracleOPUSDC / 1e30;
        assertEq(rebate, expectedRebate, "rebate matches formula");
        uint256 rebateUSDCents = (rebate * 30) / 1e18;
        assertTrue(rebateUSDCents < 10, "rebate < 10 cents");
        assertTrue(rebateUSDCents >= 1, "rebate >= 1 cent");
    }

    function testEndToEnd_RebatesAreConsistent_ETH_vs_USDC() public {
        // Discover BOTH prices via the real game flow, then compare $300-equivalent swaps.
        uint256 opWeth = _seedPrice(5, 1e16); // 1e34
        // Game 4 shares bountyParams[3] with game 5; both gameTimer = 24h. Warp past it.
        vm.warp(block.timestamp + 60 * 60 * 25);
        vm.roll(block.number + 50000);
        uint256 opUsdc = _seedPrice(4, 30e6);

        assertEq(opWeth, 1e34, "OPWETH discovered");
        assertGt(opUsdc, 3e42, "OPUSDC discovered ~3.33e42");

        vm.warp(grantFaucet.lastOpenSwapClaim() + grantFaucet.openSwapTimer() + 1);
        uint256 ethRebate = _runSwap(_ethSwapConfig(0.1 ether));

        vm.warp(grantFaucet.lastOpenSwapClaim() + grantFaucet.openSwapTimer() + 1);
        uint256 usdcRebate = _runSwap(_usdcSwapConfig(300e6));

        // Both $300 swaps -> similar rebates (~0.05 OP).
        assertApproxEqRel(ethRebate, usdcRebate, 0.2e18, "ETH and USDC rebates similar");

        uint256 ethCents = (ethRebate * 30) / 1e18;
        uint256 usdcCents = (usdcRebate * 30) / 1e18;
        assertTrue(ethCents < 10 && usdcCents < 10, "rebates small");
        assertTrue(ethCents >= 1 && usdcCents >= 1, "rebates meaningful");
    }

    function testEndToEnd_PlayBothOracleGames_ThenClaimRebates() public {
        // --- Game 5: OP/WETH ---
        uint256 opWeth = _seedPrice(5, 1e16);
        assertEq(opWeth, 1e34, "OPWETH = 1e34");

        // --- Game 4: OP/USDC (shares 24h timer; warp past it) ---
        vm.warp(block.timestamp + 60 * 60 * 25);
        vm.roll(block.number + 50000);
        uint256 opUsdc = _seedPrice(4, 30e6);
        assertGt(opUsdc, 3e42, "OPUSDC ~3.33e42");

        // --- ETH rebate from oracle-derived OPWETH ---
        vm.warp(grantFaucet.lastOpenSwapClaim() + grantFaucet.openSwapTimer() + 1);
        uint256 ethRebate = _runSwap(_ethSwapConfig(0.1 ether));
        assertEq(ethRebate, 5e16, "ETH rebate 0.05 OP");

        // --- USDC rebate from oracle-derived OPUSDC ---
        vm.warp(grantFaucet.lastOpenSwapClaim() + grantFaucet.openSwapTimer() + 1);
        uint256 usdcRebate = _runSwap(_usdcSwapConfig(300e6));
        assertApproxEqRel(usdcRebate, 5e16, 0.01e18, "USDC rebate ~0.05 OP");

        uint256 ethCents = (ethRebate * 30) / 1e18;
        uint256 usdcCents = (usdcRebate * 30) / 1e18;
        assertTrue(ethCents < 10 && usdcCents < 10, "rebates small");
    }

    // =====================================================================
    //          REBATE FAILURE DOESN'T BRICK SETTLEMENT (try/catch)
    // =====================================================================

    function testRebate_CooldownDoesNotBrickSettlement() public {
        _seedPrice(5, 1e16);
        vm.warp(block.timestamp + 61);

        // First swap pays a rebate and sets lastOpenSwapClaim (cooldown on).
        uint256 rebate1 = _runSwap(_ethSwapConfig(0.1 ether));
        assertGt(rebate1, 0, "first rebate paid");
        assertFalse(grantFaucet.feeRebateEligible(), "on cooldown");

        // Second swap within cooldown: execute() sees feeRebateEligible()==false and skips the
        // rebate entirely. The swap itself must still settle/execute successfully.
        vm.warp(block.timestamp + 10);
        uint256 rebate2 = _runSwap(_ethSwapConfig(0.1 ether));
        assertEq(rebate2, 0, "no rebate during cooldown, but swap still executed");
    }

    function testRebate_EmptyFaucetDoesNotBrickSettlement() public {
        _seedPrice(5, 1e16);
        vm.warp(block.timestamp + 61);

        // Drain ALL OP from the faucet so the OP transfer inside openSwapFeeRebate reverts.
        uint256 faucetOP = MockERC20(OP).balanceOf(address(grantFaucet));
        vm.prank(owner);
        grantFaucet.sweep(OP, faucetOP);
        assertEq(MockERC20(OP).balanceOf(address(grantFaucet)), 0, "faucet OP drained");

        // execute() wraps openSwapFeeRebate in try/catch -> the swap still succeeds, swapper gets no OP.
        uint256 rebate = _runSwap(_ethSwapConfig(0.1 ether));
        assertEq(rebate, 0, "no OP rebate from empty faucet");
    }

    function testRebate_FeeRebateEligible_ReturnsFalseOnCooldown() public {
        _seedPrice(5, 1e16);

        // Not eligible right after seeding warps? feeRebateEligible only depends on lastOpenSwapClaim.
        vm.warp(block.timestamp + 61);
        assertTrue(grantFaucet.feeRebateEligible(), "eligible before any claim");

        // A successful rebating swap sets cooldown.
        uint256 rebate = _runSwap(_ethSwapConfig(0.1 ether));
        assertGt(rebate, 0, "rebate paid");
        assertFalse(grantFaucet.feeRebateEligible(), "NOT eligible during cooldown");

        // Warp strictly past the claim + cooldown window (claim time is recorded on-chain).
        vm.warp(grantFaucet.lastOpenSwapClaim() + grantFaucet.openSwapTimer() + 1);
        assertTrue(grantFaucet.feeRebateEligible(), "eligible again after cooldown");
    }

    // =====================================================================
    //        INTERNAL PRICE REFRESH inside openSwapFeeRebate()
    // =====================================================================

    /// @dev openSwapFeeRebate() calls _updateOPPrices() itself before computing the rebate. This isolates
    ///      that path: settle a game-5 price but deliberately skip the external updateOPPrices() call, so the
    ///      faucet price is still 0 going into the swap. The rebate must still pay using the freshly settled
    ///      price — proving the internal refresh works (and would catch its removal/breakage).
    function testRebate_RefreshesPriceInternally_WithoutExternalUpdate() public {
        uint256 settledPrice = _seedPrice(5, 1e16, false); // settle, but DO NOT push to faucet
        assertEq(grantFaucet.OPWETH(), 0, "faucet price NOT refreshed externally");

        uint256 rebate = _runSwap(_ethSwapConfig(0.1 ether));

        uint256 expected = (uint256(0.1 ether) / 20000) * settledPrice / 1e30;
        assertGt(rebate, 0, "rebate paid despite no external updateOPPrices() call");
        assertEq(rebate, expected, "rebate uses the price refreshed internally by openSwapFeeRebate()");
        assertEq(grantFaucet.OPWETH(), settledPrice, "internal refresh populated OPWETH");
    }

    // =====================================================================
    //                    REBATE BOUNDARY MATRIX
    // =====================================================================

    function testBoundary_ToleranceRange_AtCap_Rebates() public {
        uint256 opWeth = _seedPrice(5, 1e16);
        vm.warp(block.timestamp + 61);
        SwapConfig memory c = _ethSwapConfig(0.1 ether);
        c.toleranceRange = 50000; // exactly at the cap
        uint256 rebate = _runSwap(c);
        assertEq(rebate, (uint256(0.1 ether) / 20000) * opWeth / 1e30, "toleranceRange == 50000 rebates");
    }

    function testBoundary_ToleranceRange_OverCap_NoRebate() public {
        _seedPrice(5, 1e16);
        vm.warp(block.timestamp + 61);
        SwapConfig memory c = _ethSwapConfig(0.1 ether);
        c.toleranceRange = 50001; // one over the cap (swap still executes; rebate guard rejects)
        uint256 rebate = _runSwap(c);
        assertEq(rebate, 0, "toleranceRange == 50001 does not rebate");
    }

    function testBoundary_ProtocolFee_AtCap_Rebates() public {
        uint256 opWeth = _seedPrice(5, 1e16);
        vm.warp(block.timestamp + 61);
        SwapConfig memory c = _ethSwapConfig(0.1 ether);
        c.protocolFee = 500; // exactly at the cap
        uint256 rebate = _runSwap(c);
        assertEq(rebate, (uint256(0.1 ether) / 20000) * opWeth / 1e30, "protocolFee == 500 rebates");
    }

    function testBoundary_ProtocolFee_OverCap_NoRebate() public {
        _seedPrice(5, 1e16);
        vm.warp(block.timestamp + 61);
        SwapConfig memory c = _ethSwapConfig(0.1 ether);
        c.protocolFee = 501; // one over the cap
        uint256 rebate = _runSwap(c);
        assertEq(rebate, 0, "protocolFee == 501 does not rebate");
    }

    // =====================================================================
    //            STALE-BUT-USABLE PRICE RETENTION
    // =====================================================================

    /// @dev _updateOPPrices() reads bounty.bountyReportId(lastBountyId[4/5]). A newer bounty that has not
    ///      been claimed/settled has bountyReportId == 0, so the refresh must be a no-op and the previous,
    ///      still-usable price must be retained (not zeroed). Pins that intentional behavior.
    function testUpdateOPPrices_RetainsPriceWhenNewerBountyUnfinalized() public {
        uint256 priceA = _seedPrice(4, 30e6);
        assertEq(grantFaucet.OPUSDC(), priceA, "price A recorded");

        // Create a newer game-4 bounty (updates lastBountyId[4]) but leave it unclaimed/unsettled.
        vm.warp(block.timestamp + 24 hours + 1); // clear game 4's 24h timer
        grantFaucet.bountyAndPriceRequest(4);

        // Newer bounty has no settled report -> refresh is a no-op, old usable price retained.
        grantFaucet.updateOPPrices();
        assertEq(grantFaucet.OPUSDC(), priceA, "stale-but-usable price retained when newer bounty unfinalized");
    }

    /// @dev Variant of the stale-price test where the newer game-4 bounty has been CLAIMED
    ///      (so bountyReportId != 0) but its oracle report is NOT settled yet (finalPrice == 0).
    ///      _updateOPPrices() reads finalPrice and must keep the previous usable price when it's still 0.
    function testUpdateOPPrices_RetainsPriceWhenNewerReportClaimedButUnsettled() public {
        uint256 priceA = _seedPrice(4, 30e6);
        assertEq(grantFaucet.OPUSDC(), priceA, "price A recorded");

        // Newer game-4 bounty, claimed (records a reportId) but deliberately NOT settled.
        vm.warp(block.timestamp + 24 hours + 1); // clear game 4's 24h timer
        uint256 bountyId = grantFaucet.bountyAndPriceRequest(4);
        IOpenOracle2.OracleGame memory og = grantFaucet.getCommittedGame(bountyId);
        openOracleBounty.Bounties memory b = _committedBounty(bountyId);

        vm.warp(b.start + 1); // past the bounty forward-start so it can be claimed
        uint128 amount1 = og.currentAmount1;
        _fund(og.token1, reporter, amount1);
        _fund(og.token2, reporter, 30e6);
        vm.startPrank(reporter);
        MockERC20(og.token1).approve(address(oracle), type(uint256).max);
        MockERC20(og.token2).approve(address(oracle), type(uint256).max);
        oracle.deposit(og.token1, amount1, reporter);
        oracle.deposit(og.token2, uint128(30e6), reporter);
        _approveInternal(reporter, address(bountyContract), og.token1);
        _approveInternal(reporter, address(bountyContract), og.token2);
        uint256 reportId = bountyContract.claimBounty(bountyId, uint128(30e6), og, b, _emptyTiming());
        vm.stopPrank();

        // The newer report id IS recorded, but it has no settled price yet.
        assertEq(bountyContract.bountyReportId(bountyId), reportId, "newer bounty recorded its report id");
        assertEq(oracle.finalPrice(reportId), 0, "newer report not settled yet (finalPrice == 0)");

        // Refresh must keep the old usable price rather than overwrite with 0.
        grantFaucet.updateOPPrices();
        assertEq(grantFaucet.OPUSDC(), priceA, "old price retained while newer report claimed-but-unsettled");
    }

    // =====================================================================
    //        SWAP BEFORE OP PRICE IS INITIALIZED (documented quirk)
    // =====================================================================

    /// @dev No game 4/5 price has ever been settled, so OPWETH is still 0. A qualifying swap runs the
    ///      rebate path but the computed amount is 0, so it must early-return WITHOUT consuming the
    ///      cooldown — leaving the faucet eligible to pay a real rebate as soon as a price exists.
    function testRebate_BeforePriceInitialized_PaysZeroAndPreservesCooldown() public {
        // Clear the initial cooldown (block.timestamp starts at 1) WITHOUT settling any price game,
        // so the rebate path actually runs while OPWETH is still 0.
        vm.warp(block.timestamp + 60);
        assertEq(grantFaucet.OPWETH(), 0, "price uninitialized");
        assertTrue(grantFaucet.feeRebateEligible(), "eligible (cooldown clear) but price still 0");

        uint256 lastClaimBefore = grantFaucet.lastOpenSwapClaim();
        uint256 rebate = _runSwap(_ethSwapConfig(0.1 ether));

        assertEq(rebate, 0, "no OP paid when price is uninitialized");
        assertEq(grantFaucet.lastOpenSwapClaim(), lastClaimBefore, "zero-value rebate leaves lastOpenSwapClaim unchanged");
        assertTrue(grantFaucet.feeRebateEligible(), "still eligible after a zero-value rebate");
    }
}
