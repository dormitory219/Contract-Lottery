// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {Lottery} from "../src/Lottery.sol";
import {AddConsumer, CreateSubscription, FundSubscription} from "./Interactions.s.sol";

contract DeployLottery is Script {
    function run() external returns (Lottery, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig(); // This comes with our mocks!
        AddConsumer addConsumer = new AddConsumer();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        // If we are on a local network, we need to create a subscription and fund it
        if (config.subscriptionId == 0) {
            CreateSubscription createSubscription = new CreateSubscription();
            (
                config.subscriptionId,
                config.vrfCoordinatorV2_5
            ) = createSubscription.createSubscription(
                config.vrfCoordinatorV2_5,
                config.account
            );

            FundSubscription fundSubscription = new FundSubscription();
            fundSubscription.fundSubscription(
                config.vrfCoordinatorV2_5,
                config.subscriptionId,
                config.link,
                config.account
            );

            helperConfig.setConfig(block.chainid, config);
        }

        // Deploy the lottery contract
        vm.startBroadcast(config.account);
        Lottery lottery = new Lottery(
            config.subscriptionId,
            config.gasLane,
            config.automationUpdateInterval,
            config.LotteryEntranceFee,
            config.callbackGasLimit,
            config.vrfCoordinatorV2_5
        );
        vm.stopBroadcast();

        // If we are on a local network, we need to add the lottery contract as a consumer
        if (block.chainid == 31337) {
            addConsumer.addConsumer(
                address(lottery),
                config.vrfCoordinatorV2_5,
                config.subscriptionId,
                config.account
            );
        }

        return (lottery, helperConfig);
    }
}
