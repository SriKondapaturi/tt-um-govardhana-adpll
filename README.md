![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# All-Digital PLL Clock Generator

A two-tile all-digital PLL fabricated on the Tiny Tapeout SKY 26c shuttle (SkyWater 130 nm). It multiplies the 10 MHz board clock up to a programmable output frequency, 40 MHz by default, using a ring-oscillator DCO built entirely from standard cells. There is no analog circuitry anywhere in the loop: phase detection is done by counting, the loop filter is a small PI accumulator, and the oscillator is tuned by switching taps along an inverter chain.

Layout: [3D viewer and project page](https://srikondapaturi.github.io/tt-um-govardhana-adpll/)

## How it works

The DCO free-runs at a frequency set by its 10-bit tuning word. A Gray-coded counter in the DCO clock domain counts oscillator cycles; the count crosses into the reference domain through a two-stage synchronizer and is sampled once every 16 reference cycles. The difference between consecutive samples is the measured cycle count for that window, and comparing it against N * 16 gives a signed frequency error. This is a counter-based time-to-digital converter with a resolution of one DCO cycle per window (625 kHz at the 10 MHz reference).

A PI filter integrates the error into the tuning word. The coarse bits of the word, `tune[9:6]`, select one of 16 taps along the ring, so the oscillator tunes in discrete steps and dithers between adjacent taps once settled; the integrator averages this dither into the intended mean frequency. Because of the dither, the lock detector does not judge single windows. It accumulates the error over groups of four windows and asserts lock only after eight consecutive groups land within two counts of target.

The target multiplier N is applied live from the input pins, so the loop can be retuned at any time without reset. Two further pins select one of four PI gain presets, trading lock speed against settling behaviour.

## The ring

The oscillator is a NAND enable gate closing a chain of 32 `inv_2` inverters, with a feedback inverter setting loop parity and a `clkbuf_4` isolating the output. Taps are taken at odd positions, `chain[2i+1]` for i in 0..15, so the loop inversion count for tap i is `1 + (2i+1) + 1 = 2i+3`, odd for every tap. Shortening the ring raises the frequency.

The chain length is derived from the tap count rather than fixed independently:

```verilog
localparam integer NTAPS   = 16;
localparam integer NSTAGES = 2 * NTAPS;   // 32 inverters
```

This matters. An earlier version declared `wire [16:0] chain` alongside a 16-tap generator, so `taps[8]` through `taps[15]` indexed `chain[17]` through `chain[31]`, which do not exist. Yosys reported `Range select out of bounds` and synthesized the top eight taps to undefined:

```verilog
assign taps = { 8'hxx, chain[15], ... chain[1] };
```

That was fatal rather than degraded. The loop resets with `ctrl = 512`, so `tune[9:6] = 8`, a dead tap from the first cycle, and its 40 MHz operating point is near `tune = 875`, tap 13, also dead. A dead tap holds the feedback node constant, which holds the NAND output constant, and the ring never starts. Deriving `NSTAGES` from `NTAPS` makes the two impossible to disagree.

## Pinout

| Pin | Function |
| --- | -------- |
| ui_in[5:0] | Target multiplier N, 1 to 63. Zero selects the default N = 4 |
| ui_in[7:6] | Loop gain preset: 00 default, 01 fast, 10 slow, 11 aggressive |
| uo_out[0] | DCO clock divided by 2 |
| uo_out[1] | Lock flag |
| uo_out[7:2] | Upper bits of the DCO tuning word, for debug |

## Hardening results (TTSKY26C flow)

Hardened on a 1x2 tile. Magic DRC and the full KLayout precheck suite pass clean, 15 rules out of 15, on the current build.

The linter reports warnings about unclocked register pins. These are the registers in the DCO clock domain: `dco_clk` is generated on-die by the ring, so the lint step has no way to recognise it as a clock. The warnings are expected for this architecture and carry no action.

Synthesis warnings are a different matter and are not treated as noise. The tap-range defect above was visible in the Yosys log the whole time, and reading that log is now part of reviewing any change to the ring.

## Verification

The testbench is cocotb driving Icarus Verilog. The behavioural DCO model is quantized to the same 16 taps the structural ring provides, so simulation exercises the discrete frequency grid the silicon actually has:

```verilog
period_ns = 60.0 - 0.04 * {tune[9:6], 6'b0};
```

An earlier version of the model used the full 10-bit tuning word, which gave simulation a 1024-step oscillator while the hardware had 16. No test could exercise the tap multiplexer, which is why the tap-range defect survived a passing regression.

The closed loop locks at 39.84 MHz for N = 4 and retunes to 29.94 MHz for N = 3, both inside one converter count of target, in under a millisecond at the default gains. The same test passes locally and in CI.

```
cd test
pip install -r requirements.txt
make -B
```

There is deliberately no gate-level simulation. The free-running ring forms a zero-delay loop in the PDK functional models under Icarus, which freezes simulation time and makes any GL run hang regardless of the testbench.

That gap is real and it has already cost something. DRC, LVS and precheck are physical checks; none of them evaluates whether the netlist computes the right thing, so none of them could see a tap multiplexer wired to undefined nodes. Between a behavioural model that did not match the hardware and a gate-level run that could not execute, nothing in the flow was looking at the synthesized ring. The mitigations are the two changes described above: the model now matches the tap grid, and synthesis warnings get read.

## Notes for silicon bring-up

The ring frequency will shift with process, voltage and temperature, so the usable N range on real silicon will differ from the behavioural model. The 32-stage chain is also longer than the earlier 16-stage one, which lowers the whole frequency band by roughly a factor of two, and no gate-level timing exists to say where it lands. The programmable multiplier and the tuning-word debug pins exist for exactly this reason: sweep N, watch `uo_out[0]` on a counter and `uo_out[7:2]` on a logic analyser, and the DCO transfer curve falls out directly. Chips are expected back around May 2027.

## License

Apache-2.0
