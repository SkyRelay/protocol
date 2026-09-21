/**
 * EIP-712 digest for SkyRelayAttestation.
 * Encoding is byte-identical to `SkyRelayBeacon.hashAttestation` in Solidity.
 */
import { address, concat, i32, u32, u64, u256, bytes32 } from "./abi.ts";
import { keccak256, keccak256Hex, utf8 } from "./keccak.ts";

export const EIP712_DOMAIN_NAME = "SkyRelay";
export const EIP712_DOMAIN_VERSION = "1";

export const ATTESTATION_TYPE_STRING =
  "SkyRelayAttestation(address operator,bytes32 telemetryHash,bytes32 catalogHash,uint32 noradId,int32 elevationMilliDeg,int32 dopplerHz,uint32 snrMilliDb,uint32 asn,uint64 timestamp)";

export const DOMAIN_TYPE_STRING =
  "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";

export const ATTESTATION_TYPEHASH = keccak256Hex(utf8(ATTESTATION_TYPE_STRING));
export const DOMAIN_TYPEHASH = keccak256Hex(utf8(DOMAIN_TYPE_STRING));

export type SkyRelayAttestation = {
  /** The only address the contract will accept as msg.sender for this beacon. */
  operator: `0x${string}`;
  telemetryHash: `0x${string}`;
  /** Commits to the element sets the geometry was resolved against. */
  catalogHash: `0x${string}`;
  noradId: number;
  elevationMilliDeg: number;
  dopplerHz: number;
  snrMilliDb: number;
  asn: number;
  timestamp: number;
};

export type Eip712Domain = {
  chainId: number;
  verifyingContract: `0x${string}`;
};

export function hashDomain(domain: Eip712Domain): Uint8Array {
  return keccak256(
    concat([
      bytes32(DOMAIN_TYPEHASH),
      keccak256(utf8(EIP712_DOMAIN_NAME)),
      keccak256(utf8(EIP712_DOMAIN_VERSION)),
      u256(BigInt(domain.chainId)),
      address(domain.verifyingContract),
    ]),
  );
}

export function hashStruct(att: SkyRelayAttestation): Uint8Array {
  return keccak256(
    concat([
      bytes32(ATTESTATION_TYPEHASH),
      address(att.operator),
      bytes32(att.telemetryHash),
      bytes32(att.catalogHash),
      u32(att.noradId),
      i32(att.elevationMilliDeg),
      i32(att.dopplerHz),
      u32(att.snrMilliDb),
      u32(att.asn),
      u64(att.timestamp),
    ]),
  );
}

export function hashTypedData(att: SkyRelayAttestation, domain: Eip712Domain): `0x${string}` {
  const prefix = new Uint8Array([0x19, 0x01]);
  return keccak256Hex(concat([prefix, hashDomain(domain), hashStruct(att)]));
}
