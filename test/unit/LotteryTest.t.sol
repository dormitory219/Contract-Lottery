// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DeployLottery} from "../../script/DeployLottery.s.sol";
import {Lottery} from "../../src/Lottery.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {LinkToken} from "../../test/mocks/LinkToken.sol";
import {CodeConstants} from "../../script/HelperConfig.s.sol";

contract LotteryTest is Test, CodeConstants {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    event RequestedLotteryWinner(uint256 indexed requestId);
    event LotteryEnter(address indexed player);
    event WinnerPicked(address indexed player);

    Lottery public lottery;
    HelperConfig public helperConfig;

    uint256 subscriptionId;
    bytes32 gasLane;
    uint256 automationUpdateInterval;
    uint256 LotteryEntranceFee;
    uint32 callbackGasLimit;
    address vrfCoordinatorV2_5;
    LinkToken link;

    address public FUNDER = makeAddr("funer");
    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant LINK_BALANCE = 100 ether;

    function setUp() external {
        DeployLottery deployer = new DeployLottery();
        (lottery, helperConfig) = deployer.run();
        vm.deal(PLAYER, STARTING_USER_BALANCE);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        subscriptionId = config.subscriptionId;
        gasLane = config.gasLane;
        automationUpdateInterval = config.automationUpdateInterval;
        LotteryEntranceFee = config.LotteryEntranceFee;
        callbackGasLimit = config.callbackGasLimit;
        vrfCoordinatorV2_5 = config.vrfCoordinatorV2_5;
        link = LinkToken(config.link);

        vm.startPrank(CodeConstants.FOUNDRY_DEFAULT_SENDER);
        if (block.chainid == LOCAL_CHAIN_ID) {
            link.mint(CodeConstants.FOUNDRY_DEFAULT_SENDER, LINK_BALANCE);
            VRFCoordinatorV2_5Mock(vrfCoordinatorV2_5).fundSubscription(
                subscriptionId,
                LINK_BALANCE
            );
        }
        link.approve(vrfCoordinatorV2_5, LINK_BALANCE);
        vm.stopPrank();
    }

    function testLotteryInitializesInOpenState() public view {
        assert(lottery.getLotteryState() == Lottery.LotteryState.OPEN);
    }

    /*//////////////////////////////////////////////////////////////
                              ENTER Lottery
    //////////////////////////////////////////////////////////////*/
    function testLotteryRevertsWHenYouDontPayEnought() public {
        // Arrange
        vm.prank(PLAYER);
        // Act / Assert
        vm.expectRevert(Lottery.Lottery__SendMoreToEnterLottery.selector);
        lottery.enterLottery();
    }

    function testLotteryRecordsPlayerWhenTheyEnter() public {
        // Arrange
        vm.prank(PLAYER);
        // Act
        lottery.enterLottery{value: LotteryEntranceFee}();
        // Assert
        address playerRecorded = lottery.getPlayer(0);
        assert(playerRecorded == PLAYER);
    }

    function testEmitsEventOnEntrance() public {
        // Arrange
        vm.prank(PLAYER);

        // Act / Assert
        vm.expectEmit(true, false, false, false, address(lottery));
        emit LotteryEnter(PLAYER);
        lottery.enterLottery{value: LotteryEntranceFee}();
    }

    function testDontAllowPlayersToEnterWhileLotteryIsCalculating() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: LotteryEntranceFee}();
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        lottery.performUpkeep("");

        // Act / Assert
        vm.expectRevert(Lottery.Lottery__LotteryNotOpen.selector);
        vm.prank(PLAYER);
        lottery.enterLottery{value: LotteryEntranceFee}();
    }

    /*//////////////////////////////////////////////////////////////
                              CHECKUPKEEP
    //////////////////////////////////////////////////////////////*/
    function testCheckUpkeepReturnsFalseIfItHasNoBalance() public {
        // Arrange
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act
        (bool upkeepNeeded, ) = lottery.checkUpkeep("");

        // Assert
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsFalseIfLotteryIsntOpen() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: LotteryEntranceFee}();
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        lottery.performUpkeep("");
        Lottery.LotteryState lotteryState = lottery.getLotteryState();
        // Act
        (bool upkeepNeeded, ) = lottery.checkUpkeep("");
        // Assert
        assert(lotteryState == Lottery.LotteryState.CALCULATING);
        assert(upkeepNeeded == false);
    }

    // Challenge 1. testCheckUpkeepReturnsFalseIfEnoughTimeHasntPassed
    function testCheckUpkeepReturnsFalseIfEnoughTimeHasntPassed() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: LotteryEntranceFee}();

        // Act
        (bool upkeepNeeded, ) = lottery.checkUpkeep("");

        // Assert
        assert(!upkeepNeeded);
    }

    // Challenge 2. testCheckUpkeepReturnsTrueWhenParametersGood
    function testCheckUpkeepReturnsTrueWhenParametersGood() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: LotteryEntranceFee}();
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act
        (bool upkeepNeeded, ) = lottery.checkUpkeep("");

        // Assert
        assert(upkeepNeeded);
    }

    /*//////////////////////////////////////////////////////////////
                             PERFORMUPKEEP
    //////////////////////////////////////////////////////////////*/
    function testPerformUpkeepCanOnlyRunIfCheckUpkeepIsTrue() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: LotteryEntranceFee}();
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act / Assert
        // It doesnt revert
        lottery.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        // Arrange
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        Lottery.LotteryState rState = lottery.getLotteryState();
        // Act / Assert
        vm.expectRevert(
            abi.encodeWithSelector(
                Lottery.Lottery__UpkeepNotNeeded.selector,
                currentBalance,
                numPlayers,
                rState
            )
        );
        lottery.performUpkeep("");
    }

    function testPerformUpkeepUpdatesLotteryStateAndEmitsRequestId() public {
        // Arrange
        vm.prank(PLAYER);
        lottery.enterLottery{value: LotteryEntranceFee}();
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);

        // Act
        vm.recordLogs();
        lottery.performUpkeep(""); // emits requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        // Assert
        Lottery.LotteryState LotteryState = lottery.getLotteryState();
        // requestId = Lottery.getLastRequestId();
        assert(uint256(requestId) > 0);
        assert(uint256(LotteryState) == 1); // 0 = open, 1 = calculating
    }

    /*//////////////////////////////////////////////////////////////
                           FULFILLRANDOMWORDS
    //////////////////////////////////////////////////////////////*/
    modifier LotteryEntered() {
        vm.prank(PLAYER);
        lottery.enterLottery{value: LotteryEntranceFee}();
        vm.warp(block.timestamp + automationUpdateInterval + 1);
        vm.roll(block.number + 1);
        _;
    }

    modifier skipFork() {
        if (block.chainid != 31337) {
            return;
        }
        _;
    }

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep()
        public
        LotteryEntered
        skipFork
    {
        // Arrange
        // Act / Assert
        vm.expectRevert(VRFCoordinatorV2_5Mock.InvalidRequest.selector);
        // vm.mockCall could be used here...
        VRFCoordinatorV2_5Mock(vrfCoordinatorV2_5).fulfillRandomWords(
            0,
            address(lottery)
        );

        vm.expectRevert(VRFCoordinatorV2_5Mock.InvalidRequest.selector);
        VRFCoordinatorV2_5Mock(vrfCoordinatorV2_5).fulfillRandomWords(
            1,
            address(lottery)
        );
    }

    function testFulfillRandomWordsPicksAWinnerResetsAndSendsMoney()
        public
        LotteryEntered
        skipFork
    {
        address expectedWinner = address(1);

        // Arrange
        uint256 additionalEntrances = 3;
        uint256 startingIndex = 1; // We have starting index be 1 so we can start with address(1) and not address(0)

        for (
            uint256 i = startingIndex;
            i < startingIndex + additionalEntrances;
            i++
        ) {
            address player = address(uint160(i));
            hoax(player, 1 ether); // deal 1 eth to the player
            lottery.enterLottery{value: LotteryEntranceFee}();

            // console2.log("*********address*********:", i);
        }

        uint256 startingTimeStamp = lottery.getLastTimeStamp();
        uint256 startingBalance = expectedWinner.balance;

        // Act
        vm.recordLogs();
        lottery.performUpkeep(""); // emits requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1]; // get the requestId from the logs

        VRFCoordinatorV2_5Mock(vrfCoordinatorV2_5).fulfillRandomWords(
            uint256(requestId),
            address(lottery)
        );

        // Assert
        address recentWinner = lottery.getRecentWinner();
        Lottery.LotteryState LotteryState = lottery.getLotteryState();
        uint256 winnerBalance = recentWinner.balance;
        uint256 endingTimeStamp = lottery.getLastTimeStamp();
        uint256 prize = LotteryEntranceFee * (additionalEntrances + 1);

        assert(recentWinner == expectedWinner);
        assert(uint256(LotteryState) == 0);
        assert(winnerBalance == startingBalance + prize);
        assert(endingTimeStamp > startingTimeStamp);
    }
}
