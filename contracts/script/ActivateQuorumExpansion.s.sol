// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {SkyRelayBeacon} from "../src/SkyRelayBeacon.sol";
import {SkyRelayBond} from "../src/SkyRelayBond.sol";

/// @title ActivateQuorumExpansion
/// @notice Activates scheduled Station 2 & 3 on BSC Mainnet SkyRelayBeacon and sets Quorum Threshold to 2 or 3.
/// @dev Can be executed once the 48-hour ROTATION_DELAY has elapsed.
contract ActivateQuorumExpansion is Script {
    address public constant MAINNET_BEACON = 0x22CE651E6916EE6488CE75657D0Da66cA11B0dC1;
    address public constant MAINNET_BOND = 0xC267E4F67e436175b6faF1D817BD4Eec3350a50d;

    function run() external {
        address station2 = vm.envAddress("STATION_2_OPERATOR");
        address station3 = vm.envAddress("STATION_3_OPERATOR");
        uint8 newThreshold = uint8(vm.envOr("TARGET_QUORUM_THRESHOLD", uint256(2)));

        SkyRelayBeacon beacon = SkyRelayBeacon(MAINNET_BEACON);
        SkyRelayBond bond = SkyRelayBond(MAINNET_BOND);

        console2.log("=== SkyRelay Quorum Activation ===");
        console2.log("Beacon:", MAINNET_BEACON);
        console2.log("Station 2:", station2);
        console2.log("Station 3:", station3);
        console2.log("Target Quorum Threshold:", newThreshold);

        vm.startBroadcast();

        // 1. Activate Station 2
        if (!beacon.isAttester(station2)) {
            uint64 eligibleAt = beacon.attesterEligibleAt(station2);
            require(eligibleAt != 0, "Station 2 not scheduled");
            require(block.timestamp >= eligibleAt, "Station 2 timelock not yet expired");
            console2.log("Activating Station 2...");
            beacon.activateAttester(station2);
        } else {
            console2.log("Station 2 is already an active attester.");
        }

        // 2. Activate Station 3
        if (!beacon.isAttester(station3)) {
            uint64 eligibleAt = beacon.attesterEligibleAt(station3);
            require(eligibleAt != 0, "Station 3 not scheduled");
            require(block.timestamp >= eligibleAt, "Station 3 timelock not yet expired");
            console2.log("Activating Station 3...");
            beacon.activateAttester(station3);
        } else {
            console2.log("Station 3 is already an active attester.");
        }

        // 3. Set Quorum Threshold
        uint8 currentThreshold = beacon.quorumThreshold();
        if (currentThreshold < newThreshold) {
            console2.log("Raising quorum threshold from", currentThreshold, "to", newThreshold);
            beacon.setQuorumThreshold(newThreshold);
            console2.log("New Quorum Threshold set successfully!");
        } else {
            console2.log("Quorum threshold already at or above target:", currentThreshold);
        }

        vm.stopBroadcast();
        console2.log("Total Active Attesters:", beacon.attesterCount());
        console2.log("Active Quorum Threshold:", beacon.quorumThreshold());
        console2.log("==================================");
    }
}
