// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {StreamPay} from "../src/StreamPay.sol";
import {MockToken} from "../src/MockToken.sol";

contract Deploy is Script {
    function run() external returns (StreamPay streamPay, MockToken token) {
        vm.startBroadcast();
        streamPay = new StreamPay();
        token = new MockToken("Stream Test USD", "sUSD");
        vm.stopBroadcast();
    }
}
