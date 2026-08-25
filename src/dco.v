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
 *    !! FLOW NOTE: combinational loops need special handling in the
 *    TT OpenLane flow (keep attributes + timing exceptions). Confirm
 *    the current recommended incantation for this shuttle on the
 *    Tiny Tapeout Discord before final hardening.
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
    real period_ns;

    always @(*) period_ns = 60.0 - (0.04 * tune);

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
    wire        fb;
    wire [16:0] chain;
    wire [15:0] taps;
    wire        tap_sel;

    // Enable NAND closes the ring (1 inversion).
    (* keep *) sky130_fd_sc_hd__nand2_2 ring_nand (
        .A (en),
        .B (fb),
        .Y (chain[0])
    );

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : g_inv
            (* keep *) sky130_fd_sc_hd__inv_2 u_inv (
                .A (chain[i]),
                .Y (chain[i+1])
            );
        end
    endgenerate

    // Taps after an odd number of inverters keep total loop inversions odd
    // (1 from NAND + odd from chain = even ... plus output buffer stage
    //  parity handled below: mux and buffer are non-inverting, so loop
    //  inversion count = 1 (NAND) + (2k+1) (chain) = even -> add one
    //  final inverter in the feedback path to restore oscillation).
    generate
        for (i = 0; i < 16; i = i + 1) begin : g_tap
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
