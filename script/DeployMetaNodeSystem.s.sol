// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {MetaNodeStake} from "../src/MetaNodeStake.sol";
import {MetaNodeToken} from "../src/MetaNode.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TestERC20} from "../src/TestERC20.sol";
import {console2} from "forge-std/console2.sol";

contract DeployMetaNodeSystem is Script {

    function setUp() public {

    }

    function run() public {
        uint256 START_BLOCK = vm.envUint("START_BLOCK");
        uint256 END_BLOCK = vm.envUint("END_BLOCK");
        uint256 PRE_BLOCK = vm.envUint("PRE_BLOCK");

        vm.startBroadcast();
        MetaNodeStake metaNodeStake = new MetaNodeStake();
        MetaNodeToken rewardToken = new MetaNodeToken();
        TestERC20 stakeToken = new TestERC20("Test Stake Token", "TST", 1000000 ether);

        ERC1967Proxy proxy = new ERC1967Proxy(address(metaNodeStake), abi.encodeCall(
            MetaNodeStake.initialize, (rewardToken, START_BLOCK, END_BLOCK, PRE_BLOCK)
        ));

        rewardToken.transfer(address(proxy), 1000000 ether);

        console2.log("reward token address", address(rewardToken));
        console2.log("stake proxy address", address(proxy));
        console2.log("stake token (TST) address", address(stakeToken));
        console2.log("stake impl address", address(metaNodeStake));

        MetaNodeStake stake = MetaNodeStake(address(proxy));
        stake.addPool(address(0), 500, 1e15, 10, false);
        console2.log("pool 0 success add");
        stake.addPool(address(stakeToken), 500, 1e15, 10, false);
        console2.log("pool 1 success add");

        vm.stopBroadcast();
    }
}