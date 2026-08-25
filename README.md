![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# All-Digital PLL Clock Generator

An all-digital phase-locked loop implemented as a Tiny Tapeout ASIC on the
SkyWater 130nm process (shuttle TTSKY26C). Multiplies a 10 MHz reference
clock by a programmable factor N (1-63), targeting 40 MHz at the default
N=4, with on-chip lock detection.

## Architecture

| Block | Implementation |
| ----- | -------------- |
| Phase detector | Counter-based TDC: Gray-coded DCO cycle counter, CDC into ref domain, 16-ref-cycle measurement windows |
| Loop filter | Digital PI, four selectable gain presets |
| DCO | Ring oscillator, hand-instantiated sky130_fd_sc_hd cells, 16-tap coarse tuning |
| Lock detector | Mean error over 4 windows within +/-2 counts for 8 consecutive groups |

## Interface

| Pin | Function |
| --- | -------- |
| `ui_in[5:0]` | Target multiplier N (0 selects default N=4) |
| `ui_in[7:6]` | Loop gain preset (00 default, 01 fast, 10 slow, 11 aggressive) |
| `uo_out[0]` | DCO clock / 2 |
| `uo_out[1]` | Lock flag |
| `uo_out[7:2]` | DCO tuning word MSBs (debug) |

## Verification

Cocotb + Icarus Verilog. RTL simulation uses a behavioral DCO model
(linear tune-to-period); the closed loop locks at 39.81 MHz for N=4 and
retunes to 30.46 MHz for N=3, lock time ~650 us at the default gains.

```
cd test
pip install -r requirements.txt
make -B          # RTL
make -B GATES=yes  # gate level (after GDS action)
```

## Status

- [x] RTL complete, cocotb verified
- [ ] Confirm ring-oscillator combinational-loop flow config (Discord)
- [ ] GDS action green, gate-level sim
- [ ] Silicon bring-up (chips ~May 2027)

## License

Apache 2.0.
