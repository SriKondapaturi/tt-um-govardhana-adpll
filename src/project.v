/*
 * tt_um_govardhana_adpll -- All-Digital PLL Clock Generator
 * Tiny Tapeout SKY 26c
 *
 * Architecture:
 *   - Counter-based time-to-digital phase/frequency detector:
 *     a Gray-coded counter in the DCO domain is synchronized into the
 *     reference domain; DCO cycles are counted over a 16-reference-cycle
 *     window and compared against target N*16.
 *   - Digital PI loop filter with selectable gain presets.
 *   - Ring-oscillator DCO (see dco.v) with 10-bit tuning word.
 *   - Lock detector: error is averaged over groups of 4 windows and lock
 *     asserts after 8 consecutive groups whose mean is within 2 counts,
 *     i.e. 32 windows of qualification. The averaging is there because a
 *     tap-quantized DCO dithers between adjacent taps once settled.
 *
 * Pinout:
 *   clk          : reference clock from TT board (e.g. 10 MHz)
 *   ui_in[5:0]   : target multiplier N (1..63); 0 selects default N=4
 *   ui_in[7:6]   : loop gain preset (00 default, 01 fast, 10 slow, 11 aggressive)
 *   uo_out[0]    : DCO clock / 2 (for scope / frequency counter)
 *   uo_out[1]    : lock flag
 *   uo_out[7:2]  : tuning word MSBs (debug)
 *   uio          : unused (all inputs)
 */

`default_nettype none

module tt_um_govardhana_adpll (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ------------------------------------------------------------------
    // Configuration inputs (async, synchronized into ref domain)
    // ------------------------------------------------------------------
    reg [7:0] cfg_s1, cfg_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_s1 <= 8'h00;
            cfg_s2 <= 8'h00;
        end else begin
            cfg_s1 <= ui_in;
            cfg_s2 <= cfg_s1;
        end
    end

    wire [5:0] target_n = (cfg_s2[5:0] == 6'd0) ? 6'd4 : cfg_s2[5:0];
    wire [1:0] gain_sel = cfg_s2[7:6];

    // ------------------------------------------------------------------
    // DCO
    // ------------------------------------------------------------------
    wire [9:0] tune;
    wire       dco_clk;

    dco u_dco (
        .en      (rst_n),
        .tune    (tune),
        .dco_clk (dco_clk)
    );

    // ------------------------------------------------------------------
    // DCO-domain: reset synchronizer, Gray-coded cycle counter, /2 output
    // ------------------------------------------------------------------
    reg [1:0] dco_rst_sync;
    always @(posedge dco_clk or negedge rst_n) begin
        if (!rst_n) dco_rst_sync <= 2'b00;
        else        dco_rst_sync <= {dco_rst_sync[0], 1'b1};
    end
    wire dco_rst_n = dco_rst_sync[1];

    reg [11:0] dco_bin;
    reg [11:0] dco_gray;
    reg        dco_div2;
    wire [11:0] dco_bin_nxt = dco_bin + 12'd1;

    always @(posedge dco_clk or negedge dco_rst_n) begin
        if (!dco_rst_n) begin
            dco_bin  <= 12'd0;
            dco_gray <= 12'd0;
            dco_div2 <= 1'b0;
        end else begin
            dco_bin  <= dco_bin_nxt;
            dco_gray <= dco_bin_nxt ^ (dco_bin_nxt >> 1);
            dco_div2 <= ~dco_div2;
        end
    end

    // ------------------------------------------------------------------
    // Ref-domain: synchronize Gray counter, decode, windowed measurement
    // ------------------------------------------------------------------
    reg [11:0] gray_s1, gray_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gray_s1 <= 12'd0;
            gray_s2 <= 12'd0;
        end else begin
            gray_s1 <= dco_gray;
            gray_s2 <= gray_s1;
        end
    end

    function [11:0] gray2bin;
        input [11:0] g;
        integer i;
        begin
            gray2bin[11] = g[11];
            for (i = 10; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    wire [11:0] cnt_now = gray2bin(gray_s2);

    reg  [3:0]  win_cnt;
    reg  [11:0] cnt_prev;
    reg         tick;          // 1 for one ref cycle at end of each window
    reg  [11:0] meas;          // DCO cycles counted in last window

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_cnt  <= 4'd0;
            cnt_prev <= 12'd0;
            tick     <= 1'b0;
            meas     <= 12'd0;
        end else begin
            win_cnt <= win_cnt + 4'd1;
            tick    <= 1'b0;
            if (win_cnt == 4'd15) begin
                meas     <= cnt_now - cnt_prev;   // mod-4096 wrap-safe
                cnt_prev <= cnt_now;
                tick     <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Error and PI loop filter (updates on tick)
    // ------------------------------------------------------------------
    wire [9:0]         target16 = {target_n, 4'b0000};       // N * 16
    wire signed [12:0] err = $signed({3'b000, target16}) -
                             $signed({1'b0,  meas});

    // Gain presets: kp_rs = right-shift of err for P term,
    //               ki_ls = left-shift of err for I term.
    reg [1:0] kp_rs;
    reg [1:0] ki_ls;
    always @(*) begin
        case (gain_sel)
            2'b00:   begin kp_rs = 2'd2; ki_ls = 2'd2; end  // default
            2'b01:   begin kp_rs = 2'd1; ki_ls = 2'd3; end  // fast
            2'b10:   begin kp_rs = 2'd3; ki_ls = 2'd1; end  // slow
            default: begin kp_rs = 2'd2; ki_ls = 2'd3; end  // aggressive I
        endcase
    end

    localparam signed [20:0] ACC_INIT = 21'sd16384;          // 512 << 5
    localparam signed [20:0] ACC_MAX  = 21'sd32736;          // 1023 << 5
    localparam signed [20:0] ACC_MIN  = 21'sd0;

    reg  signed [20:0] acc;
    wire signed [20:0] acc_nxt_raw = acc + ($signed({{8{err[12]}}, err}) <<< ki_ls);
    wire signed [20:0] acc_nxt =
        (acc_nxt_raw > ACC_MAX) ? ACC_MAX :
        (acc_nxt_raw < ACC_MIN) ? ACC_MIN : acc_nxt_raw;

    wire signed [13:0] prop = err >>> kp_rs;
    wire signed [16:0] ctrl_pre = $signed({1'b0, acc[20:5]}) + $signed({{3{prop[13]}}, prop});
    wire [9:0] ctrl_sat =
        (ctrl_pre < 17'sd0)    ? 10'd0    :
        (ctrl_pre > 17'sd1023) ? 10'd1023 : ctrl_pre[9:0];

    reg [9:0] ctrl;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc  <= ACC_INIT;
            ctrl <= 10'd512;
        end else if (tick) begin
            acc  <= acc_nxt;
            ctrl <= ctrl_sat;
        end
    end

    assign tune = ctrl;

    // ------------------------------------------------------------------
    // Lock detector
    // ------------------------------------------------------------------
    // Average error over groups of 4 windows so coarse-DCO tap dither
    // does not defeat the lock check (silicon rings tune in steps).
    reg  signed [14:0] err_acc;
    reg         [1:0]  grp_cnt;
    reg         [3:0]  lock_cnt;
    wire signed [14:0] err_acc_nxt = err_acc + {{2{err[12]}}, err};
    wire signed [14:0] acc_abs = err_acc_nxt[14] ? -err_acc_nxt : err_acc_nxt;
    wire grp_in_band = (acc_abs <= 15'sd8);   // avg |err| <= 2 counts

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            err_acc  <= 15'sd0;
            grp_cnt  <= 2'd0;
            lock_cnt <= 4'd0;
        end else if (tick) begin
            grp_cnt <= grp_cnt + 2'd1;
            if (grp_cnt == 2'd3) begin
                err_acc  <= 15'sd0;
                lock_cnt <= grp_in_band ? ((lock_cnt == 4'd8) ? 4'd8
                                                              : lock_cnt + 4'd1)
                                        : 4'd0;
            end else begin
                err_acc <= err_acc_nxt;
            end
        end
    end
    wire locked = (lock_cnt == 4'd8);

    // ------------------------------------------------------------------
    // Outputs
    // ------------------------------------------------------------------
    assign uo_out[0]   = dco_div2;
    assign uo_out[1]   = locked;
    assign uo_out[7:2] = ctrl[9:4];

    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;

    // Silence unused-signal lint
    wire _unused = &{ena, uio_in, 1'b0};

endmodule
