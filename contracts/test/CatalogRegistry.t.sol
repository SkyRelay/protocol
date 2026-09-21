// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CatalogRegistry} from "../src/CatalogRegistry.sol";

contract CatalogRegistryTest is Test {
    CatalogRegistry internal registry;
    address internal owner = makeAddr("owner");
    bytes32 internal constant HASH = keccak256("catalog-2026-263");

    function setUp() public {
        registry = new CatalogRegistry(owner);
    }

    function test_ownerStartsAsRegistrar() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.registrar(), owner);
        assertFalse(registry.isRegistered(HASH));
    }

    function test_registerStoresLocatorAndTimestamp() public {
        vm.warp(1_789_918_203);
        vm.prank(owner);
        registry.register(HASH, "gnfd://skyrelay-catalog/2026-09-20T2000Z.tle");

        assertTrue(registry.isRegistered(HASH));
        (uint64 at, string memory locator) = registry.catalogs(HASH);
        assertEq(at, 1_789_918_203);
        assertEq(locator, "gnfd://skyrelay-catalog/2026-09-20T2000Z.tle");
    }

    function test_registeringTheSameHashTwiceReverts() public {
        vm.startPrank(owner);
        registry.register(HASH, "gnfd://skyrelay-catalog/a.tle");
        vm.expectRevert(CatalogRegistry.AlreadyRegistered.selector);
        registry.register(HASH, "gnfd://skyrelay-catalog/b.tle");
        vm.stopPrank();

        // the original locator is unchanged
        (, string memory locator) = registry.catalogs(HASH);
        assertEq(locator, "gnfd://skyrelay-catalog/a.tle");
    }

    function test_locatorIsOpaque() public {
        // the contract must not parse or validate the locator; a garbage
        // string is as acceptable as a Greenfield URI
        vm.prank(owner);
        registry.register(HASH, "not-a-uri-at-all");
        assertTrue(registry.isRegistered(HASH));
        (, string memory locator) = registry.catalogs(HASH);
        assertEq(locator, "not-a-uri-at-all");
    }

    function test_strangerCannotRegister() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(CatalogRegistry.NotRegistrar.selector);
        registry.register(HASH, "gnfd://x");
    }

    function test_ownerCanReplaceRegistrar() public {
        address next = makeAddr("registrar");
        vm.prank(owner);
        registry.setRegistrar(next);

        vm.prank(owner);
        vm.expectRevert(CatalogRegistry.NotRegistrar.selector);
        registry.register(HASH, "gnfd://x");

        vm.prank(next);
        registry.register(HASH, "gnfd://x");
        assertTrue(registry.isRegistered(HASH));
    }

    function test_zeroHashReverts() public {
        vm.prank(owner);
        vm.expectRevert(CatalogRegistry.ZeroHash.selector);
        registry.register(bytes32(0), "gnfd://x");
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(CatalogRegistry.ZeroAddress.selector);
        new CatalogRegistry(address(0));
    }
}
