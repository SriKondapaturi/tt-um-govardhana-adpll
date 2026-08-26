/*
 * dco.v -- Digitally Controlled Oscillator
 *
 * Two implementations selected by `SIM:
 *
 * 1. SIMULATION (`SIM defined): behavioral model with a linear
 *    tune-to-period characteristic:
 *        period_ns = 60.0 - 0.04 * tune      (tune = 0..1023)
 *    i.e. ~16.7 MHz at tune=0 up to ~52 MHz at tune=1023,
 *    crossing 40 MHz (25 ns) near tune = 875.
 *
 * 2. SYNTHESIS: structural ring oscillator built from hand-instantiated
 *    SKY130 HD cells with (* keep *) attributes so Yosys does not
 *    optimize the loop away.
 *      - Coarse tuning: tune[9:6] selects one of 16 taps along an
 *        inverter chain (ring length -> frequency).
 *      - tune[5:0] fine bits are reserved (dithered by the loop; the
 *        PI integrator naturally averages between adjacent taps).
 *
 *    Hardening note: the keep attributes are sufficient for the
 *    TTSKY26C LibreLane flow. Synthesis, placement, routing, DRC/LVS
 *    and the Tiny Tapeout precheck all pass with the loop intact.
 */

`default_nettype none

module dco (
    input  wire       en,
    input  wire [9:0] tune,
    output wire       dco_clk
);

`ifdef SIM
    // ---------------- Behavioral model (simulation only) --------------
    reg clk_r = 1'b0;
