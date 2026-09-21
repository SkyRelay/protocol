import { ALLOWED_ASN, STARLINK_ASN } from "../orbit/constants.ts";

export type AsnVerdict = {
  asn: number;
  allowed: boolean;
  reason: string;
};

export function classifyAsn(asn: number): AsnVerdict {
  if (!Number.isInteger(asn) || asn <= 0) {
    return { asn, allowed: false, reason: "ASN must be a positive integer" };
  }
  if (ALLOWED_ASN.has(asn)) {
    const tag = asn === STARLINK_ASN.PRIMARY ? "SPACEX-STARLINK" : "IDNIC-STARLINK";
    return { asn, allowed: true, reason: `${tag} is in the Starlink customer allow-set` };
  }
  return {
    asn,
    allowed: false,
    reason: `ASN ${asn} is outside {${STARLINK_ASN.PRIMARY}, ${STARLINK_ASN.INDONESIA}}`,
  };
}

export function assertStarlinkAsn(asn: number): void {
  const v = classifyAsn(asn);
  if (!v.allowed) throw new Error(v.reason);
}
