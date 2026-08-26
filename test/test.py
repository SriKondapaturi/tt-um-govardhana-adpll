# SPDX-License-Identifier: Apache-2.0
# Cocotb testbench for tt_um_govardhana_adpll (ADPLL clock generator)
#
# RTL sim: behavioral DCO -- full closed-loop test: lock at N=4 (40 MHz),
#          retune to N=3 (30 MHz), frequency assertions.
# Gate-level sim (GATES=yes): SMOKE TEST ONLY. A free-running ring at
#          unit delays makes long GL sims explode in event count, so we
#          only verify the synthesized ring oscillates and the output
#          divider toggles. Loop dynamics are covered at RTL.

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ValueChange, Timer
from cocotb.utils import get_sim_time

def _is_gl(dut):
    """GL if env says so OR the behavioral DCO signal is absent (netlist)."""
    if os.environ.get("GATES", "no") == "yes":
        return True
    try:
        _ = dut.user_project.u_dco.period_ns
        return False
    except Exception:
        return True


async def measure_dco_mhz(dut, n_edges=64):
    """Measure DCO frequency via rising edges of uo_out[0] (DCO/2)."""
    prev = int(dut.uo_out.value) & 1
    t0 = None
    edges = 0
    while True:
        await ValueChange(dut.uo_out)
        cur = int(dut.uo_out.value) & 1
        if cur == 1 and prev == 0:
            if t0 is None:
                t0 = get_sim_time(unit="ns")
            else:
                edges += 1
                if edges == n_edges:
                    t1 = get_sim_time(unit="ns")
                    return 2.0 * 1000.0 * n_edges / (t1 - t0)
        prev = cur


async def count_out_toggles(dut, window_ns, sample_ns=25):
    """Count uo_out[0] transitions by periodic sampling (hang-proof)."""
    toggles = 0
    prev = int(dut.uo_out.value) & 1
    for _ in range(int(window_ns // sample_ns)):
        await Timer(sample_ns, unit="ns")
        cur = int(dut.uo_out.value) & 1
        if cur != prev:
            toggles += 1
            prev = cur
        if toggles >= 32:          # plenty of proof; bail out early
            break
    return toggles


async def wait_for_lock(dut, timeout_cycles=30000):
    for _ in range(timeout_cycles // 100):
        await ClockCycles(dut.clk, 100)
        if int(dut.uo_out.value) & 0x02:
            return True
    return False


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def test_adpll(dut):
    # 10 MHz reference clock
    cocotb.start_soon(Clock(dut.clk, 100, unit="ns").start())

    # Reset with N=4 (x4 -> 40 MHz), default gain preset
    dut.ena.value = 1
    dut.ui_in.value = 4
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    if _is_gl(dut):
        # ---- Gate-level smoke test: ring alive, divider toggling -------
        dut._log.info("GL detected: running smoke test")
        await ClockCycles(dut.clk, 20)
        dut._log.info("GL smoke: reset released, sampling output")
        toggles = await count_out_toggles(dut, window_ns=5000)
        dut._log.info(f"GL smoke: {toggles} output toggles in 5 us window")
        assert toggles >= 8, "Synthesized DCO ring does not oscillate"
        dut._log.info("GL smoke test PASSED")
        return

    # ---- RTL: full closed-loop test -----------------------------------
    assert await wait_for_lock(dut), "ADPLL failed to lock at N=4"
    await ClockCycles(dut.clk, 2000)

    dco_mhz = await measure_dco_mhz(dut)
    dut._log.info(f"N=4: DCO = {dco_mhz:.2f} MHz (target 40.00)")
    assert abs(dco_mhz - 40.0) < 2.0, f"DCO {dco_mhz:.2f} MHz != ~40 MHz"

    dut.ui_in.value = 3
    await ClockCycles(dut.clk, 400)

    assert await wait_for_lock(dut), "ADPLL failed to relock at N=3"
    await ClockCycles(dut.clk, 2000)

    dco_mhz = await measure_dco_mhz(dut)
    dut._log.info(f"N=3: DCO = {dco_mhz:.2f} MHz (target 30.00)")
    assert abs(dco_mhz - 30.0) < 2.0, f"DCO {dco_mhz:.2f} MHz != ~30 MHz"

    dut._log.info("ADPLL lock + retune PASSED")
