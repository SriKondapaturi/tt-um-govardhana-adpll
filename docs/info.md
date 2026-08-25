## How it works

An all-digital PLL that multiplies the board reference clock (10 MHz) by a
programmable factor N (1-63, set on ui[5:0]; 0 selects the default N=4 for
40 MHz output).

A free-running ring-oscillator DCO (hand-instantiated SKY130 cells, coarse
tap-select tuning) is measured by a counter-based time-to-digital detector:
a Gray-coded cycle counter in the DCO domain is synchronized into the
reference domain and sampled over 16-reference-cycle windows. The count is
compared against N*16, and the signed error drives a digital PI loop filter
(four selectable gain presets on ui[7:6]) that updates the 10-bit DCO
tuning word. A lock detector asserts uo[1] when the error stays within
+/-2 counts (~1.25 MHz) for 15 consecutive windows.

## How to test

Apply a 10 MHz clock, release reset with ui = 0x04 (N=4). Watch uo[0] with
a scope or frequency counter: it outputs DCO/2, so expect ~20 MHz once
uo[1] (lock) goes high. Change ui[5:0] to retune; uo[7:2] exposes the
tuning word MSBs for debugging loop behavior in silicon.

## External hardware

None required. A scope or frequency counter on uo[0] is recommended.
