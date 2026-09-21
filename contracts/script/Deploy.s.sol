// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {SkyRelayBeacon} from "../src/SkyRelayBeacon.sol";

contract Deploy is Script {
    function run() external {
        address owner = vm.envAddress("OWNER");
        address attester = vm.envAddress("ATTESTER");
        address vault = vm.envAddress("ORBITAL_VAULT");
        vm.startBroadcast();
        new SkyRelayBeacon(owner, attester, vault);
        vm.stopBroadcast();
    }
}
