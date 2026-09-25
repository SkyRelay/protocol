// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {SkyRelayBeacon} from "../src/SkyRelayBeacon.sol";
import {SkyRelayBond} from "../src/SkyRelayBond.sol";

/// @title ScheduleQuorumExpansion
/// @notice Schedules Station 2 (Hebrides) and Station 3 (Faroe Islands) on BSC Mainnet SkyRelayBeacon.
/// @dev Enforces the 2-day timelock before activating multi-station BFT quorum (Threshold >= 2 or 3).
contract ScheduleQuorumExpansion is Script {
    address public constant MAINNET_BEACON = 0x22CE651E6916EE6488CE75657D0Da66cA11B0dC1;
    address public constant MAINNET_BOND = 0xC267E4F67e436175b6faF1D817BD4Eec3350a50d;

    function run() external {
        address station2 = vm.envAddress("STATION_2_OPERATOR");
        address station3 = vm.envAddress("STATION_3_OPERATOR");

        SkyRelayBeacon beacon = SkyRelayBeacon(MAINNET_BEACON);
        SkyRelayBond bond = SkyRelayBond(MAINNET_BOND);

        address owner = beacon.owner();
        console2.log("=== SkyRelay Quorum Expansion (Phase 1) ===");
        console2.log("Beacon Contract:", MAINNET_BEACON);
        console2.log("Owner Address:", owner);
        console2.log("Current Attester Count:", beacon.attesterCount());
        console2.log("Current Quorum Threshold:", beacon.quorumThreshold());
        console2.log("Station 2 Candidate (Hebrides):", station2);
        console2.log("Station 3 Candidate (Faroe Islands):", station3);

        vm.startBroadcast();

        // 1. Schedule Station 2
        if (!beacon.isAttester(station2) && beacon.attesterEligibleAt(station2) == 0) {
            console2.log("Scheduling Station 2 attester...");
            beacon.scheduleAttester(station2);
            console2.log("Station 2 Eligible At (timestamp):", beacon.attesterEligibleAt(station2));
        } else {
            console2.log("Station 2 is already scheduled or active.");
        }

        // 2. Schedule Station 3
        if (!beacon.isAttester(station3) && beacon.attesterEligibleAt(station3) == 0) {
            console2.log("Scheduling Station 3 attester...");
            beacon.scheduleAttester(station3);
            console2.log("Station 3 Eligible At (timestamp):", beacon.attesterEligibleAt(station3));
        } else {
            console2.log("Station 3 is already scheduled or active.");
        }

        vm.stopBroadcast();

        console2.log("--------------------------------------------------");
        console2.log("Next Steps after 48h (ROTATION_DELAY):");
        console2.log("1. Ensure Station 2 and 3 deposit >= 0.001 BNB bond into SkyRelayBond.");
        console2.log("2. Call beacon.activateAttester(station2) and beacon.activateAttester(station3).");
        console2.log("3. Owner calls beacon.setQuorumThreshold(2 or 3) [takes effect IMMEDIATELY].");
        console2.log("==================================================");
    }
}
