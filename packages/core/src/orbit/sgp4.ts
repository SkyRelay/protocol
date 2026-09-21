/**
 * Near-Earth SGP4 (orbital period < 225 min).
 *
 * Follows Vallado, Crawford, Hujsak & Kelso, AIAA 2006-6753, WGS-72.
 * SDP4 is omitted: Starlink (~91–96 min) and the Vanguard-1 verification
 * case (~133 min) are both near-Earth. Output is TEME, km and km/s.
 */
import { CK2, CK4, J3OJ2, TWO_PI, WGS72, X2O3, XKE } from "./constants.ts";
import { meanMotionRadPerMin, tleAnglesRad, type Tle } from "./tle.ts";

export type Vec3 = readonly [number, number, number];

export type Sgp4State = {
  tle: Tle;
  no: number;
  aodp: number;
  bstar: number;
  inclo: number;
  nodeo: number;
  argpo: number;
  mo: number;
  ecco: number;
  isimp: boolean;
  eta: number;
  c1: number;
  c4: number;
  c5: number;
  d2: number;
  d3: number;
  d4: number;
  t2cof: number;
  t3cof: number;
  t4cof: number;
  t5cof: number;
  xmdot: number;
  omgdot: number;
  nodedot: number;
  nodecf: number;
  xlcof: number;
  aycof: number;
  delmo: number;
  sinmao: number;
  omgcof: number;
  xmcof: number;
};

export type Sgp4Result = {
  positionKm: Vec3;
  velocityKmS: Vec3;
};

function wrapTwoPi(a: number): number {
  let x = a % TWO_PI;
  if (x < 0) x += TWO_PI;
  return x;
}

export function initSgp4(tle: Tle): Sgp4State {
  const { inclo, nodeo, argpo, mo } = tleAnglesRad(tle);
  const ecco = tle.eccentricity;
  const bstar = tle.bstar;
  const noKozai = meanMotionRadPerMin(tle);
  if (ecco < 0 || ecco >= 1) throw new Error(`eccentricity ${ecco} not in [0, 1)`);
  if (noKozai <= 0) throw new Error("mean motion must be positive");

  const cosio = Math.cos(inclo);
  const sinio = Math.sin(inclo);
  const theta2 = cosio * cosio;
  const x3thm1 = 3 * theta2 - 1;
  const eosq = ecco * ecco;
  const betao2 = 1 - eosq;
  const betao = Math.sqrt(betao2);

  // Vallado initl un-Kozai (AIAA 2006-6753). d1 uses J2, not CK2.
  const ak = (XKE / noKozai) ** X2O3;
  const d1 = (0.75 * WGS72.j2 * x3thm1) / (betao * betao2);
  let del = d1 / (ak * ak);
  const adel = ak * (1 - del * del - del * (1 / 3 + (134 / 81) * del * del));
  del = d1 / (adel * adel);
  const no = noKozai / (1 + del);
  const ao = (XKE / no) ** X2O3;
  const aodp = ao;

  const periodMin = TWO_PI / no;
  if (periodMin >= 225) {
    throw new Error(`SDP4 deep-space (P=${periodMin.toFixed(1)} min) not implemented`);
  }

  const rp = aodp * (1 - ecco);
  const perigeeKm = (rp - 1) * WGS72.radiusEarthKm;
  const isimp = perigeeKm < 220;

  let s4 = 78 / WGS72.radiusEarthKm + 1;
  let qoms24 = ((120 - 78) / WGS72.radiusEarthKm) ** 4;
  if (perigeeKm < 156) {
    s4 = perigeeKm <= 98 ? 20 / WGS72.radiusEarthKm + 1 : perigeeKm / WGS72.radiusEarthKm - 0.015 + 1;
    qoms24 = Math.max(1.012229 - s4, 0) ** 4;
  }

  const tsi = 1 / (ao - s4);
  const eta = ao * ecco * tsi;
  const etasq = eta * eta;
  const eeta = ecco * eta;
  const psisq = Math.abs(1 - etasq);
  const coef = qoms24 * tsi ** 4;
  const coef1 = coef / psisq ** 3.5;
  const c2 =
    coef1 *
    no *
    (ao * (1 + 1.5 * etasq + eeta * (4 + etasq)) +
      ((0.75 * CK2 * tsi) / psisq) * x3thm1 * (8 + 3 * etasq * (8 + etasq)));
  const c1 = bstar * c2;
  const c3 = ecco > 1e-4 ? (-2 * coef * tsi * J3OJ2 * no * sinio) / ecco : 0;
  const x1mth2 = 1 - theta2;
  const c4 =
    2 *
    no *
    coef1 *
    ao *
    betao2 *
    (eta * (2 + 0.5 * etasq) +
      ecco * (0.5 + 2 * etasq) -
      ((2 * CK2 * tsi) / (ao * psisq)) *
        (-3 * x3thm1 * (1 - 2 * eeta + etasq * (1.5 - 0.5 * eeta)) +
          0.75 * x1mth2 * (2 * etasq - eeta * (1 + etasq)) * Math.cos(2 * argpo)));
  const c5 = 2 * coef1 * ao * betao2 * (1 + 2.75 * (etasq + eeta) + eeta * etasq);

  const theta4 = theta2 * theta2;
  const pinvsq = 1 / (aodp * aodp * betao2 * betao2);
  const temp1 = 3 * CK2 * pinvsq * no;
  const temp2 = temp1 * CK2 * pinvsq;
  const temp3 = 1.25 * CK4 * pinvsq * pinvsq * no;
  const xmdot =
    no + 0.5 * temp1 * betao * x3thm1 + 0.0625 * temp2 * betao * (13 - 78 * theta2 + 137 * theta4);
  const x1m5th = 1 - 5 * theta2;
  const omgdot =
    -0.5 * temp1 * x1m5th +
    0.0625 * temp2 * (7 - 114 * theta2 + 395 * theta4) +
    temp3 * (3 - 36 * theta2 + 49 * theta4);
  const xhdot1 = -temp1 * cosio;
  const nodedot =
    xhdot1 + (0.5 * temp2 * (4 - 19 * theta2) + 2 * temp3 * (3 - 7 * theta2)) * cosio;
  const nodecf = 3.5 * betao2 * xhdot1 * c1;
  const t2cof = 1.5 * c1;
  const xlcof =
    Math.abs(cosio + 1) > 1.5e-12
      ? (-0.25 * J3OJ2 * sinio * (3 + 5 * cosio)) / (1 + cosio)
      : (-0.25 * J3OJ2 * sinio * (3 + 5 * cosio)) / 1.5e-12;
  const aycof = -0.5 * J3OJ2 * sinio;
  const delmo = (1 + eta * Math.cos(mo)) ** 3;
  const sinmao = Math.sin(mo);
  const omgcof = bstar * c3 * Math.cos(argpo);
  const xmcof = Math.abs(ecco) > 1e-4 ? (-X2O3 * coef * bstar) / eeta : 0;

  const cc1sq = c1 * c1;
  const d2 = 4 * ao * tsi * cc1sq;
  const temp = (d2 * tsi * c1) / 3;
  const d3 = (17 * ao + s4) * temp;
  const d4 = 0.5 * temp * ao * tsi * (221 * ao + 31 * s4) * c1;
  const t3cof = d2 + 2 * cc1sq;
  const t4cof = 0.25 * (3 * d3 + c1 * (12 * d2 + 10 * cc1sq));
  const t5cof = 0.2 * (3 * d4 + 12 * c1 * d3 + 6 * d2 * d2 + 15 * cc1sq * (2 * d2 + cc1sq));

  return {
    tle,
    no,
    aodp,
    bstar,
    inclo,
    nodeo,
    argpo,
    mo,
    ecco,
    isimp,
    eta,
    c1,
    c4,
    c5,
    d2,
    d3,
    d4,
    t2cof,
    t3cof,
    t4cof,
    t5cof,
    xmdot,
    omgdot,
    nodedot,
    nodecf,
    xlcof,
    aycof,
    delmo,
    sinmao,
    omgcof,
    xmcof,
  };
}

export function propagate(state: Sgp4State, tsinceMin: number): Sgp4Result {
  const t = tsinceMin;
  const t2 = t * t;
  const xmdf = state.mo + state.xmdot * t;
  const argpdf = state.argpo + state.omgdot * t;
  const nodedf = state.nodeo + state.nodedot * t;
  let argpm = argpdf;
  let mm = xmdf;
  const nodem = nodedf + state.nodecf * t2;
  let tempa = 1 - state.c1 * t;
  let tempe = state.bstar * state.c4 * t;
  let templ = state.t2cof * t2;

  if (!state.isimp) {
    const delomg = state.omgcof * t;
    const delm = state.xmcof * ((1 + state.eta * Math.cos(xmdf)) ** 3 - state.delmo);
    const temp = delomg + delm;
    mm = xmdf + temp;
    argpm = argpdf - temp;
    const t3 = t2 * t;
    const t4 = t3 * t;
    tempa = tempa - state.d2 * t2 - state.d3 * t3 - state.d4 * t4;
    tempe += state.bstar * state.c5 * (Math.sin(mm) - state.sinmao);
    templ = templ + state.t3cof * t3 + t4 * (state.t4cof + t * state.t5cof);
  }

  if (tempa <= 0) {
    throw new Error("semi-major axis collapsed (decay)");
  }

  const am = state.aodp * tempa * tempa;
  const nm = XKE / am ** 1.5;
  const em = state.ecco - tempe;
  if (em >= 1 || em < -0.001) {
    throw new Error(`mean eccentricity ${em} out of range`);
  }

  const xlm = mm + argpm + nodem + state.no * templ;
  const nodep = wrapTwoPi(nodem);
  const argpp = argpm;
  const mp = wrapTwoPi(xlm - argpm - nodem);

  const axnl = em * Math.cos(argpp);
  const temp = 1 / (am * (1 - em * em));
  const xl = mp + argpp + nodep + temp * state.xlcof * axnl;
  const aynl = em * Math.sin(argpp) + temp * state.aycof;

  const capu = wrapTwoPi(xl - nodep);
  let epw = capu;
  let sinepw = Math.sin(epw);
  let cosepw = Math.cos(epw);
  for (let i = 0; i < 10; i++) {
    const f = capu - aynl * cosepw + axnl * sinepw - epw;
    const fdot = 1 - cosepw * axnl - sinepw * aynl;
    let delta = f / fdot;
    if (Math.abs(delta) > 0.95) delta = Math.sign(delta) * 0.95;
    epw += delta;
    sinepw = Math.sin(epw);
    cosepw = Math.cos(epw);
    if (Math.abs(delta) < 1e-12) break;
  }

  const ecose = axnl * cosepw + aynl * sinepw;
  const esine = axnl * sinepw - aynl * cosepw;
  const el2 = axnl * axnl + aynl * aynl;
  const pl = am * (1 - el2);
  if (pl < 0) throw new Error("semilatus rectum < 0");
  const r = am * (1 - ecose);
  let temp2 = 1 / r;
  // Vallado rdotl / rvdotl: these carry no xke factor. The short-period
  // corrections applied to them below are the terms that are divided by xke.
  const rdot = Math.sqrt(am) * esine * temp2;
  const rfdot = Math.sqrt(pl) * temp2;
  temp2 = am * temp2;
  const betal = Math.sqrt(Math.max(0, 1 - el2));
  const temp3 = esine / (1 + betal);
  const cosu = temp2 * (cosepw - axnl + aynl * temp3);
  const sinu = temp2 * (sinepw - aynl - axnl * temp3);
  const u = Math.atan2(sinu, cosu);
  const sin2u = 2 * sinu * cosu;
  const cos2u = 1 - 2 * sinu * sinu;
  const temp4 = 1 / pl;
  const temp1 = CK2 * temp4;
  const temp5 = temp1 * temp4;

  const cosio = Math.cos(state.inclo);
  const sinio = Math.sin(state.inclo);
  const x3thm1 = 3 * cosio * cosio - 1;
  const x1mth2 = 1 - cosio * cosio;
  const x7thm1 = 7 * cosio * cosio - 1;

  const mrt = r * (1 - 1.5 * temp5 * betal * x3thm1) + 0.5 * temp1 * x1mth2 * cos2u;
  const su = u - 0.25 * temp5 * x7thm1 * sin2u;
  const xnode = nodep + 1.5 * temp5 * cosio * sin2u;
  const xinc = state.inclo + 1.5 * temp5 * cosio * sinio * cos2u;
  const mvt = rdot - (nm * temp1 * x1mth2 * sin2u) / XKE;
  const rvdot = rfdot + (nm * temp1 * (x1mth2 * cos2u + 1.5 * x3thm1)) / XKE;

  if (mrt < 1) throw new Error("decayed (mrt < 1)");

  const sinsu = Math.sin(su);
  const cossu = Math.cos(su);
  const snod = Math.sin(xnode);
  const cnod = Math.cos(xnode);
  const sini = Math.sin(xinc);
  const cosi = Math.cos(xinc);
  const xmx = -snod * cosi;
  const xmy = cnod * cosi;
  const ux = xmx * sinsu + cnod * cossu;
  const uy = xmy * sinsu + snod * cossu;
  const uz = sini * sinsu;
  const vx = xmx * cossu - cnod * sinsu;
  const vy = xmy * cossu - snod * sinsu;
  const vz = sini * cossu;

  const vkmpersec = (WGS72.radiusEarthKm * XKE) / 60;
  return {
    positionKm: [mrt * ux * WGS72.radiusEarthKm, mrt * uy * WGS72.radiusEarthKm, mrt * uz * WGS72.radiusEarthKm],
    velocityKmS: [
      (mvt * ux + rvdot * vx) * vkmpersec,
      (mvt * uy + rvdot * vy) * vkmpersec,
      (mvt * uz + rvdot * vz) * vkmpersec,
    ],
  };
}

export function propagateTle(tle: Tle, tsinceMin: number): Sgp4Result {
  return propagate(initSgp4(tle), tsinceMin);
}
