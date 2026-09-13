// tb_mux_all.cpp full mux test (stateful + stateless paths)
//
// funct3 encoding:
//   0 CMD_WRITE_ADDR   (stateful)
//   1 CMD_WRITE_DATA   (stateful)
//   2 CMD_START        (stateful)
//   3 mac_plus_5       (stateless)
//   4 crc_step         (stateless)
//   5 hwx_simd_mac   (stateless)
//   6 hwx_saturating_add (stateless)
//   7 hwx_barrett_reduction (stateless)
#include <iostream>
#include <verilated.h>
#include "Vhwx_mux.h"

static int failures = 0;
static void check(const char* name, uint32_t got, uint32_t expected) {
    if (got == expected) std::cout << "  [PASS] " << name << " = " << got << std::endl;
    else { std::cout << "  [FAIL] " << name << " = " << got << " (expected " << expected << ")" << std::endl; failures++; }
}

// Drive one stateless instruction through the mux
static uint32_t run_stateless(Vhwx_mux* dut, int funct3, uint32_t rs1, uint32_t rs2) {
    dut->funct3_i = funct3;
    dut->rs1_i = rs1;
    dut->rs2_i = rs2;
    dut->start_i = 1;
    dut->stall_i = 0;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->start_i = 0;

    int cycles = 0;
    while (!dut->done_o && cycles++ < 50) {
        dut->clk_i = 0; dut->eval();
        dut->clk_i = 1; dut->eval();
    }
    return dut->rd_o;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vhwx_mux* dut = new Vhwx_mux;

    dut->rst_ni = 0;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->rst_ni = 1;

    std::cout << "=== Full Mux Tests ===" << std::endl;

    // Stateless datapaths
    std::cout << "Stateless datapaths:" << std::endl;
    check("mac_plus_5 (3*4+5)", run_stateless(dut, 3, 3, 4), 17);

    // crc_step: data=1 (odd, LSB=1) → (1>>1) ^ 0x04C11DB7 = 0x04C11DB7
    check("crc_step (data=1)", run_stateless(dut, 4, 1, 0), 0x04C11DB7);

    // simd_mac: 2*3 = 6
    check("simd_mac (2*3)", run_stateless(dut, 5, 0x00000002, 0x00000003), 6);

    // saturating: 127+1 → 127 (lane 0)
    check("saturating (127+1)", run_stateless(dut, 6, 0x0000007F, 0x00000001), 0x0000007F);

    // barrett: 12290 mod 12289 = 1
    check("barrett (12290 mod 12289)", run_stateless(dut, 7, 12290, 0), 1);

    // Stateful commands
    std::cout << "Stateful commands (Montgomery):" << std::endl;

    // CMD_WRITE_ADDR: select bank=0 (A), word=0
    dut->funct3_i = 0;
    dut->rs1_i = 0x00000000;
    dut->start_i = 1;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->start_i = 0;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    std::cout << "  [INFO] CMD_WRITE_ADDR done" << std::endl;

    // CMD_WRITE_DATA: write A[0]=5
    dut->funct3_i = 1;
    dut->rs1_i = 5;
    dut->start_i = 1;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->start_i = 0;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    std::cout << "  [INFO] CMD_WRITE_DATA (A[0]=5) done" << std::endl;

    // CMD_WRITE_ADDR: select bank=1 (B), word=0
    dut->funct3_i = 0;
    dut->rs1_i = 0x00010000;
    dut->start_i = 1;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->start_i = 0;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();

    // CMD_WRITE_DATA: write B[0]=7
    dut->funct3_i = 1;
    dut->rs1_i = 7;
    dut->start_i = 1;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->start_i = 0;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    std::cout << "  [INFO] CMD_WRITE_DATA (B[0]=7) done" << std::endl;

    // CMD_START: trigger Montgomery compute
    dut->funct3_i = 2;
    dut->start_i = 1;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->start_i = 0;

    int cycles = 0;
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

    std::cout << (failures == 0 ? "ALL MUX TESTS PASSED" : "MUX TESTS FAILED") << std::endl;
    delete dut;
    return failures == 0 ? 0 : 1;
}
