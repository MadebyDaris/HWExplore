// Verilator testbench for a generated HWExplore datapath module.
// Tests the standard HWExplore port interface:
//   clk_i, rst_ni, start_i, rs1_i, rs2_i, rd_o, done_o
//
// Expected DUT: mac_plus_5  ->  result = (rs1 * rs2) + 5
//   rs1=3, rs2=4 => (3*4)+5 = 17
//   Latency: 4 cycles (MUL=2 cycles, ADD=1 cycle)

#include "f_1.h"
#include "verilated.h"
#include <iostream>

static vluint64_t sim_time = 0;

double sc_time_stamp() { return sim_time; }

// Toggle clock and evaluate
static void tick(Vf_1* dut) {
    dut->clk_i = 0; dut->eval(); sim_time++;
    dut->clk_i = 1; dut->eval(); sim_time++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vf_1* dut = new Vf_1;

    // Reset
    dut->rst_ni  = 0;
    dut->start_i = 0;
    dut->stall_i = 0;
    dut->rs1_i   = 0;
    dut->rs2_i   = 0;
    tick(dut);
    tick(dut);
    dut->rst_ni  = 1;

    // Drive inputs: rs1=3, rs2=4, expected=(3*4)+5=17
    dut->rs1_i   = 4;
    dut->rs2_i   = 3;
    dut->start_i = 1;
    tick(dut);
    dut->start_i = 0;

    // Wait for done_o — poll for up to 10 cycles
    int timeout = 10;
    while (!dut->done_o && timeout-- > 0) {
        tick(dut);
    }

    if (dut->done_o) {
        std::cout << "done_o asserted" << std::endl;
        std::cout << "rd_o = " << dut->rd_o << "  (expected 17)" << std::endl;
        if (dut->rd_o == 17)
            std::cout << "TEST PASSED" << std::endl;
        else
            std::cout << "TEST FAILED" << std::endl;
    } else {
        std::cout << "Timeout waiting for done_o — TEST FAILED" << std::endl;
    }

    delete dut;
    return 0;
}
