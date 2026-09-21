# Orbital proof — SGP4, look angles, Ku Doppler

## 1. Why SGP4

NORAD / CelesTrak publish **two-line element sets** fitted to the Simplified General Perturbations 4 model (Hoots & Roehrich, Spacetrack Report #3; Vallado et al., AIAA 2006-6753). A TLE is not an osculating Keplerian state. Propagating it with a Kepler two-body integrator is a category error. SkyRelay therefore implements **near-Earth SGP4** (period \(P < 225\) min) in `packages/core/src/orbit/sgp4.ts`, WGS-72 constants:

\[
R_\oplus = 6378.135\,\mathrm{km},\quad
\mu = 398600.8\,\mathrm{km}^3\mathrm{s}^{-2},\quad
J_2 = 1.082616\times 10^{-3}.
\]

Starlink user-downlink shells have \(P \approx 91\text{–}96\) min, so SDP4 (deep space) is never entered.

Output of SGP4 is a TEME position \(\mathbf{r}\) and velocity \(\mathbf{v}\).

### Verification

The implementation is pinned against satellite 00005 in the **published** SGP4 verification output that accompanies AIAA 2006-6753 — external numbers at nine significant digits, not a baseline captured from this code:

| \(t\) (min) | position residual | velocity residual |
|---|---|---|
| 0 | \(6.8\times10^{-9}\) km | \(6.4\times10^{-10}\) km/s |
| 360 | \(6.1\times10^{-9}\) km | \(3.8\times10^{-10}\) km/s |

Velocity is pinned deliberately. An earlier revision of this file carried an `xke` factor on `rdotl`/`rvdotl` without the compensating division on the short-period terms; position was exact and every Doppler number was 13.4× too small. A position-only check cannot see that. `packages/core/test/sgp4.test.ts` therefore also asserts that the analytic velocity agrees with the numerical derivative of the position, and that the speed satisfies vis-viva.

SGP4's analytic velocity is not the exact derivative of its own position expression — the short-period periodics are differentiated only in part — so the numerical check uses a relative bound of \(10^{-3}\), against an inherent residual of \(2\times10^{-4}\) (eccentric) and \(2\times10^{-6}\) (near-circular).

The propagator is also checked against satellite.js on every element set in `vectors/tle/` at \(t = 0, 12.5, 45, 200, 720\) min. Worst residual: \(1.8\times10^{-10}\) km in position, \(1.6\times10^{-13}\) km/s in velocity (`packages/core/test/crossval.test.ts`).

Be precise about what that buys. satellite.js is a port of the same Vallado/CelesTrak reference code, so agreement at the \(10^{-10}\) km level reflects shared lineage rather than independent confirmation of the algorithm — the published table above is what covers the algorithm itself. What the cross-check does establish is that our transcription is faithful: a dropped term, a mistyped constant or a sign error anywhere in those 300 lines would surface immediately, including on the near-circular Starlink sets the published table never touches.

## 2. TEME → ECEF

Greenwich mean sidereal time \(\theta\) (Vallado `gstime`) rotates TEME about \(Z\):

\[
\mathbf{r}_\mathrm{ECEF}
=
\begin{pmatrix}
\cos\theta & \sin\theta & 0 \\
-\sin\theta & \cos\theta & 0 \\
0 & 0 & 1
\end{pmatrix}
\mathbf{r}_\mathrm{TEME}.
\]

For **velocity** the same rotation is not enough. ECEF rotates, so the transport term must come off:

\[
\mathbf{v}_\mathrm{ECEF} = R(\theta)\,\mathbf{v}_\mathrm{TEME} - \boldsymbol\omega\times\mathbf{r}_\mathrm{ECEF},
\qquad \omega = 7.292115\times10^{-5}\,\mathrm{rad\,s^{-1}}.
\]

Omitting it biases the line-of-sight range-rate by up to \(|\boldsymbol\omega||\mathbf{r}| \approx 0.5\,\mathrm{km\,s^{-1}}\) — about 19 kHz at Ku. The test `range-rate is the time derivative of range` compares the reported \(\dot\rho\) against a central difference of the reported \(\rho\) and fails without the term.

## 3. The station is on an ellipsoid

A station at geodetic \((\varphi,\lambda,h)\) is placed with the prime-vertical radius

\[
N(\varphi) = \frac{R_\oplus}{\sqrt{1-e^2\sin^2\varphi}},\qquad e^2 = f(2-f),\qquad f = 1/298.26,
\]

not at \(R_\oplus + h\). The spherical shortcut misplaces the station by ~2.1 km radially at \(\varphi = 18.2^\circ\), and — the part that matters — tilts the local vertical by \(f\sin 2\varphi \approx 0.11^\circ\) there, up to \(0.19^\circ\) at mid latitudes. The attestation stores elevation in milli-degrees, so that is a systematic bias of a hundred quanta. Using the geodetic latitude also makes the position consistent with the SEZ basis, whose zenith is by definition the ellipsoid normal.

## 4. Look angles

For a station at geodetic \((\varphi,\lambda,h)\) the topocentric south-east-zenith (SEZ) components of \(\mathbf{\rho} = \mathbf{r}_\mathrm{sat}-\mathbf{r}_\mathrm{sta}\) give

\[
\varepsilon = \arcsin(\rho_Z / \rho),\qquad
\alpha = \mathrm{atan2}(\rho_E, -\rho_S).
\]

Elevation \(\varepsilon\) is what the contract stores (milli-degrees). A beacon with \(\varepsilon\le 0\) is rejected (`BelowHorizon`).

## 5. Doppler

Line-of-sight range-rate \(\dot\rho = \mathbf{v}_\mathrm{rel}\cdot\hat{\rho}\), with \(\mathbf{v}_\mathrm{rel}\) in ECEF per §2. The one-way Ku downlink shift at carrier \(f_c = 11.7\,\mathrm{GHz}\) is the classical formula

\[
f_d = -\frac{\dot\rho}{c}\,f_c,\qquad c = 299792.458\,\mathrm{km\,s}^{-1}.
\]

At LEO, \(|\dot\rho|\lesssim 7\,\mathrm{km\,s}^{-1}\) so \(|f_d|\lesssim 270\,\mathrm{kHz}\); it passes through zero at closest approach, which is why the committed fixtures are placed off the peak of their passes and land between 145 and 227 kHz. Relativistic and ionospheric terms are \(\sim 10^{-8}\) relative and sit below SGP4's kilometre-class geometric error; they are omitted on purpose.

## 6. 15-second handover clock

Independent measurements (Tanveer et al. and follow-ups) show Starlink UT–satellite reassignment is globally aligned to UTC second offsets **12 / 27 / 42 / 57**. The feature extractor records the next slot and the remaining seconds. This is a **timing fingerprint**, not a Solidity computation.

## 7. What this does *not* prove

SGP4 plus a Dishy JSON file does not prove the JSON came from a particular silicon UT, nor that the operator stood where it says it did. What §3–§5 buy is narrower and real: the capture is only attested if a satellite in the public catalog was genuinely within 2° of where the terminal claims to have been pointing, at the second the attestation commits to. A fabricated frame has to be consistent with a real orbit, a real station, and a real instant — all three at once — instead of being a number someone chose.
