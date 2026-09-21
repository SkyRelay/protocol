// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {SkyRelayBeacon} from "../src/SkyRelayBeacon.sol";
import {SkyRelayBond} from "../src/SkyRelayBond.sol";
import {CatalogRegistry} from "../src/CatalogRegistry.sol";

contract Deploy is Script {
    function run() external {
        address owner = vm.envAddress("OWNER");
        address attester = vm.envAddress("ATTESTER");
        address vault = vm.envAddress("ORBITAL_VAULT");
        uint256 minBond = vm.envOr("MIN_BOND", uint256(1 ether));
        uint64 unbondingPeriod = uint64(vm.envOr("UNBONDING_PERIOD", uint256(7 days)));
        uint16 reporterBountyBps = uint16(vm.envOr("REPORTER_BOUNTY_BPS", uint256(1000)));

        vm.startBroadcast();

        CatalogRegistry catalog = new CatalogRegistry(owner);

        // Bond needs the beacon address to recompute EIP-712 digests; the
        // beacon needs the bond address to check isActive. The beacon address
        // is determined by the broadcaster's nonce, so we predict it.
        address deployer = msg.sender;
        uint64 nonce = vm.getNonce(deployer);
        address predictedBeacon = vm.computeCreateAddress(deployer, nonce + 1);

        SkyRelayBond bond_ = new SkyRelayBond(minBond, unbondingPeriod, reporterBountyBps, vault, predictedBeacon);
        SkyRelayBeacon beacon_ = new SkyRelayBeacon(owner, attester, vault, address(catalog), address(bond_));
        require(address(beacon_) == predictedBeacon, "beacon address mismatch");

        vm.stopBroadcast();
    }
}
