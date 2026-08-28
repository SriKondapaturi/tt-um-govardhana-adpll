/*
 * dco.v -- Digitally Controlled Oscillator
 *
 * Two implementations selected by `SIM:
 *
 * 1. SIMULATION (`SIM defined): behavioral model with a linear
 *    tune-to-period characteristic, quantized to the same 16 taps the
 *    structural ring provides:
 *        period_ns = 60.0 - 0.04 * {tune[9:6], 6'b0}
 *    i.e. ~16.7 MHz at tap 0 up to ~46 MHz at tap 15.
 *
 * 2. SYNTHESIS: structural ring oscillator built from hand-instantiated
 *    SKY130 HD cells with (* keep *) attributes so Yosys does not
 *    optimize the loop away.
 *      - Coarse tuning: tune[9:6] selects one of NTAPS taps along an
 *        inverter chain (ring length -> frequency).
 *      - tune[5:0] fine bits are reserved.
 *
 *    Hardening note: the keep attributes are sufficient for the
 *    TTSKY26C LibreLane flow. Synthesis, placement, routing, DRC/LVS
 *    and the Tiny Tapeout precheck all pass with the loop intact.
 *
 * ---------------------------------------------------------------------
 * FIX (tap index range)
 *
 * The chain was previously 16 inverters, declared wire [16:0] chain,
 * while the tap generator indexed chain[2*i+1] for i = 0..15, i.e.
 * chain[1] .. chain[31]. Everything from i = 8 upward was out of range.
 * Yosys reported it and tied those eight taps to undefined:
 *
 *   dco.v: Warning: Range select out of bounds on signal '\chain':
 *                   Setting result bit to undef.
 *   assign taps = { 8'hxx, chain[15], ... chain[1] };
 *
 * That is fatal, not cosmetic. project.v resets with ctrl = 512, so
 * tune[9:6] = 8, a dead tap, from the first cycle; and the loop's target
 * near tune = 875 is tap 13, also dead. With a dead tap the feedback node
 * is constant, the NAND output is constant, and the ring never starts.
 *
 * A chain of NSTAGES inverters only contains NSTAGES/2 odd-numbered
 * nodes, so 16 taps was never available from 16 inverters. The chain is
 * now sized from the tap count rather than fixed, so the two cannot
 * disagree again:
 *
 *     NSTAGES = 2 * NTAPS
 *     highest tap index = 2*(NTAPS-1)+1 = NSTAGES-1  <=  NSTAGES   OK
 *
 * The behavioural model is also quantized to the same taps now. It
 * previously used the full 10-bit tune, giving simulation a 1024-step
 * oscillator while the hardware had 16 steps, which is why no test ever
 * exercised the tap multiplexer.
 * ---------------------------------------------------------------------
 */

`default_nettype none

module dco (
    input  wire       en,
    input  wire [9:0] tune,
    output wire       dco_clk
);

    // Tap count is what tune[9:6] can address; the chain length follows
    // from it. Do not set these independently.
    localparam integer NTAPS   = 16;
    localparam integer NSTAGES = 2 * NTAPS;   // 32 inverters

`ifdef SIM
    // ---------------- Behavioral model (simulation only) --------------
    // Quantized to the tap grid so simulation exercises the same
    // sixteen discrete frequencies the silicon can produce.
    wire [9:0] tune_q = {tune[9:6], 6'b0};

    reg clk_r = 1'b0;
    real period_ns;

    always @(*) period_ns = 60.0 - (0.04 * tune_q);

    always begin
        if (en) begin
            #(period_ns / 2.0) clk_r = ~clk_r;
        end else begin
            clk_r = 1'b0;
            #1;
        end
    end

    assign dco_clk = clk_r;

`else
    // ---------------- Structural SKY130 ring (synthesis) ---------------
    wire               fb;
    wire [NSTAGES:0]   chain;
    wire [NTAPS-1:0]   taps;
    wire               tap_sel;

    // Enable NAND closes the ring (1 inversion).
    (* keep *) sky130_fd_sc_hd__nand2_2 ring_nand (
        .A (en),
        .B (fb),
        .Y (chain[0])
    );

    genvar i;
    generate
        for (i = 0; i < NSTAGES; i = i + 1) begin : g_inv
            (* keep *) sky130_fd_sc_hd__inv_2 u_inv (
                .A (chain[i]),
                .Y (chain[i+1])
            );
        end
    endgenerate

    // Taps sit after an odd number of inverters. Total loop inversions
    // for tap i = 1 (NAND) + (2i+1) (chain) + 1 (feedback inverter)
    //            = 2i + 3, which is odd for every i, so every tap
    // oscillates. The highest index used is 2*(NTAPS-1)+1 = NSTAGES-1,
    // which is inside chain[NSTAGES:0] by construction.
    generate
        for (i = 0; i < NTAPS; i = i + 1) begin : g_tap
            assign taps[i] = chain[2*i + 1];
        end
    endgenerate

    // Coarse mux: tune[9:6] selects ring length.
    assign tap_sel = taps[tune[9:6]];

    // Feedback inverter fixes loop parity (total inversions odd).
    (* keep *) sky130_fd_sc_hd__inv_2 u_fb_inv (
        .A (tap_sel),
        .Y (fb)
    );

    // Output buffer isolates the ring from the clock tree load.
    (* keep *) sky130_fd_sc_hd__clkbuf_4 u_obuf (
        .A (fb),
        .X (dco_clk)
    );

    wire _unused = &{tune[5:0], 1'b0};
`endif

endmodule
