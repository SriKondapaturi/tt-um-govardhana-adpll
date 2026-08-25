# SPDX-License-Identifier: Apache-2.0
# Cocotb testbench for tt_um_govardhana_adpll (ADPLL clock generator)
#
# RTL sim: behavioral DCO (linear tune->period), checks lock + frequency.
# Gate-level sim (GATES=yes): unit-delay ring quantizes frequencies, so
# only lock acquisition is asserted, frequencies are logged informally.

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ValueChange
from cocotb.utils import get_sim_time

GL_TEST = os.environ.get("GATES", "no") == "yes"


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


async def wait_for_lock(dut, timeout_cycles=30000):
    for _ in range(timeout_cycles // 100):
        await ClockCycles(dut.clk, 100)
        if int(dut.uo_out.value) & 0x02:
            return True
    return False


@cocotb.test()
async def test_adpll_lock(dut):
    # 10 MHz reference clock
    cocotb.start_soon(Clock(dut.clk, 100, unit="ns").start())

    # Reset with N=4 (x4 -> 40 MHz), default gain preset
    dut.ena.value = 1
    dut.ui_in.value = 4
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    # --- Test 1: lock at N=4 -------------------------------------------
    assert await wait_for_lock(dut), "ADPLL failed to lock at N=4"
    await ClockCycles(dut.clk, 2000)  # settle after lock

    dco_mhz = await measure_dco_mhz(dut)
    dut._log.info(f"N=4: DCO = {dco_mhz:.2f} MHz (target 40.00)")
    if not GL_TEST:
        assert abs(dco_mhz - 40.0) < 2.0, f"DCO {dco_mhz:.2f} MHz != ~40 MHz"

    # --- Test 2: retune to N=3 (30 MHz) --------------------------------
    dut.ui_in.value = 3
    await ClockCycles(dut.clk, 400)

    assert await wait_for_lock(dut), "ADPLL failed to relock at N=3"
    await ClockCycles(dut.clk, 2000)

    dco_mhz = await measure_dco_mhz(dut)
    dut._log.info(f"N=3: DCO = {dco_mhz:.2f} MHz (target 30.00)")
    if not GL_TEST:
        assert abs(dco_mhz - 30.0) < 2.0, f"DCO {dco_mhz:.2f} MHz != ~30 MHz"

    dut._log.info("ADPLL lock + retune PASSED")
