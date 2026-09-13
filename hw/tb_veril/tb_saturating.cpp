// tb_saturating.cpp standalone saturating add test (4 lanes, 8-bit signed)
#include <iostream>
#include <verilated.h>
#include "Vhwx_saturating_add.h"

static int failures = 0;
static void check(const char* name, uint32_t got, uint32_t expected) {
    if (got == expected) std::cout << "  [PASS] " << name << " = 0x" << std::hex << got << std::dec << std::endl;
    else { std::cout << "  [FAIL] " << name << " = 0x" << std::hex << got << " (expected 0x" << expected << ")" << std::dec << std::endl; failures++; }
}

static uint32_t pack(int a, int b, int c, int d) {
    return ((uint32_t)(uint8_t)a) | ((uint32_t)(uint8_t)b << 8) |
           ((uint32_t)(uint8_t)c << 16) | ((uint32_t)(uint8_t)d << 24);
}

static void run_one(Vhwx_saturating_add* dut, uint32_t rs1, uint32_t rs2, uint32_t expected) {
    dut->rs1_i = rs1;
    dut->rs2_i = rs2;
    dut->start_i = 1;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->start_i = 0;
    int cycles = 0;
    while (!dut->done_o && cycles++ < 10) {
        dut->clk_i = 0; dut->eval();
        dut->clk_i = 1; dut->eval();
    }
    char name[64];
    snprintf(name, sizeof(name), "sat_add(0x%08x, 0x%08x)", rs1, rs2);
    check(name, dut->rd_o, expected);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vhwx_saturating_add* dut = new Vhwx_saturating_add;

    dut->rst_ni = 0;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->rst_ni = 1;

    std::cout << "Saturating add tests (4x8-bit signed):" << std::endl;
    // Normal: 1+1=2
    run_one(dut, pack(1,1,1,1), pack(1,1,1,1), pack(2,2,2,2));
    // Overflow: 127+1 → saturate to 127
    run_one(dut, pack(127,0,0,0), pack(1,0,0,0), pack(127,0,0,0));
    // Underflow: -128 + -1 → saturate to -128
    run_one(dut, pack(-128,0,0,0), pack(-1,0,0,0), pack(-128,0,0,0));
    // Mixed: lane0 saturates (127+127→127), lane1 normal (5+5=10)
    run_one(dut, pack(127,5,0,0), pack(127,5,0,0), pack(127,10,0,0));

    std::cout << (failures == 0 ? "ALL SATURATING ADD TESTS PASSED" : "SATURATING ADD TESTS FAILED") << std::endl;
    delete dut;
    return failures == 0 ? 0 : 1;
}
