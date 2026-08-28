## How it works

An all-digital PLL that multiplies the board reference clock (10 MHz) by a
programmable factor N (1-63, set on ui[5:0]; 0 selects the default N=4 for
40 MHz output).

A free-running ring-oscillator DCO, hand-instantiated from SKY130 standard
cells, is measured by a counter-based time-to-digital detector: a Gray-coded
cycle counter in the DCO domain is synchronized into the reference domain and
sampled over 16-reference-cycle windows. The count is compared against N*16,
and the signed error drives a digital PI loop filter (four selectable gain
presets on ui[7:6]) that updates the 10-bit DCO tuning word.

The ring is a NAND enable gate closing a chain of 32 inverters. The coarse
tuning bits, tune[9:6], select one of 16 taps at odd positions along that
chain, so the oscillator tunes in 16 discrete steps and dithers between
adjacent taps once settled. Because of that dither the lock detector averages:
it accumulates the error over groups of four windows and asserts uo[1] only
after eight consecutive groups stay within two counts (about 1.25 MHz) of
target.

## How to test

Apply a 10 MHz clock, release reset with ui = 0x04 (N=4). Watch uo[0] with
a scope or frequency counter: it outputs DCO/2, so expect ~20 MHz once
uo[1] (lock) goes high. Change ui[5:0] to retune; uo[7:2] exposes the
tuning word MSBs for debugging loop behavior in silicon.

Note that the frequency of a standard-cell ring shifts substantially with
process, voltage and temperature, and no gate-level timing exists for this
design, so the achievable N range on real silicon is not known in advance.
Sweeping N while reading uo[0] and uo[7:2] together is the intended way to
extract the DCO transfer curve from the part.

## External hardware

None required. A scope or frequency counter on uo[0] is recommended, and a
logic analyser on uo[7:2] is useful for reading the tuning word.
