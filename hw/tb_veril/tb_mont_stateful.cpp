// tb_mont_stateful.cpp — Montgomery adapter stateful interface test
//
// Tests the stateful command protocol:
//   1. CMD_WRITE_ADDR (we_i + addr_i) writes operand words
//   2. CMD_START (start_i) triggers Montgomery compute
//   3. done_o asserts, rd_o returns result
//
// Uses legacy mode fallback: start_i also loads rs1_i→A[0], rs2_i→B[0].
// For N=997, R=1024: computes (a*b*R^-1) mod N.
#include <iostream>
#include <verilated.h>
#include "Vhwx_mont_adapter.h"

static int failures = 0;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vhwx_mont_adapter* dut = new Vhwx_mont_adapter;

    dut->rst_ni = 0;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->rst_ni = 1;

    std::cout << "Montgomery adapter stateful tests (N=997, R=1024):" << std::endl;

    // Test 1: legacy mode — start loads A[0]=5, B[0]=7
    dut->rs1_i = 5;
    dut->rs2_i = 7;
    dut->addr_i = 0;
    dut->wdata_i = 0;
    dut->we_i = 0;
    dut->stall_i = 0;
    dut->start_i = 1;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->start_i = 0;

    // Wait for done (variable latency — up to 200 cycles)
    int cycles = 0;
    while (!dut->done_o && cycles++ < 200) {
        dut->clk_i = 0; dut->eval();
        dut->clk_i = 1; dut->eval();
    }
    if (dut->done_o) {
        std::cout << "  [PASS] Montgomery completed in " << cycles << " cycles, result = " << dut->rd_o << std::endl;
    } else {
        std::cout << "  [FAIL] Montgomery did not complete (timed out)" << std::endl;
        failures++;
    }

    // Test 2: stateful write via we_i/addr_i
    dut->rst_ni = 0;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->rst_ni = 1;
    dut->start_i = 0;
    dut->rs1_i = 0;
    dut->rs2_i = 0;

    // Write A[0] = 6 via bank=0, word=0
    dut->addr_i = 0x00000000;  // bank=0 (A), word=0
    dut->wdata_i = 6;
    dut->we_i = 1;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->we_i = 0;

    // Write B[0] = 8 via bank=1, word=0
    dut->addr_i = 0x00010000;  // bank=1 (B), word=0
    dut->wdata_i = 8;
    dut->we_i = 1;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->we_i = 0;

    // Trigger compute
    dut->start_i = 1;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->start_i = 0;

    cycles = 0;
    while (!dut->done_o && cycles++ < 200) {
        dut->clk_i = 0; dut->eval();
        dut->clk_i = 1; dut->eval();
    }
    if (dut->done_o) {
        std::cout << "  [PASS] Stateful Montgomery completed in " << cycles << " cycles, result = " << dut->rd_o << std::endl;
    } else {
        std::cout << "  [FAIL] Stateful Montgomery did not complete" << std::endl;
        failures++;
    }

    std::cout << (failures == 0 ? "ALL MONTGOMERY TESTS PASSED" : "MONTGOMERY TESTS FAILED") << std::endl;
    delete dut;
    return failures == 0 ? 0 : 1;
}
