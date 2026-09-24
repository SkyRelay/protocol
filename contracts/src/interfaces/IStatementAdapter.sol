// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStatementAdapter
/// @notice Extracts equivocation-checking primitives from domain-specific signed statements.
/// @dev An adapter is fully trusted by EquivocationBond to determine what constitutes a conflict.
///      It MUST be immutable and audited alongside the bond.
interface IStatementAdapter {
    /// @notice Decode raw statement payload into canonical equivocation dimensions.
    /// @param statement ABI-encoded domain statement.
    /// @return subject The constrained identity (e.g. operator/station address).
    /// @return slot The dimension across which contradiction is forbidden (e.g. timestamp or round).
    /// @return digest The cryptographic digest that was signed by the attester.
    function parseStatement(bytes calldata statement)
        external
        view
        returns (address subject, bytes32 slot, bytes32 digest);
}
