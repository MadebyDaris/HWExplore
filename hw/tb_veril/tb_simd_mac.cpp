// tb_simd_mac.cpp — standalone SIMD MAC test (4 lanes, 8-bit signed)
#include <iostream>
#include <verilated.h>
#include "Vhwx_simd_mac.h"

static int failures = 0;
static void check(const char* name, uint32_t got, uint32_t expected) {
    if (got == expected) std::cout << "  [PASS] " << name << " = " << got << std::endl;
    else { std::cout << "  [FAIL] " << name << " = " << got << " (expected " << expected << ")" << std::endl; failures++; }
}

// Pack 4 signed 8-bit lanes into a 32-bit word (LS lane first)
static uint32_t pack(int a, int b, int c, int d) {
    return ((uint32_t)(uint8_t)a) | ((uint32_t)(uint8_t)b << 8) |
           ((uint32_t)(uint8_t)c << 16) | ((uint32_t)(uint8_t)d << 24);
}

static void run_one(Vhwx_simd_mac* dut, uint32_t rs1, uint32_t rs2, uint32_t expected) {
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
    snprintf(name, sizeof(name), "simd_mac(0x%08x, 0x%08x)", rs1, rs2);
    check(name, dut->rd_o, expected);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vhwx_simd_mac* dut = new Vhwx_simd_mac;

    dut->rst_ni = 0;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->rst_ni = 1;

    std::cout << "SIMD MAC tests (4x8-bit signed, ACCUMULATES across calls):" << std::endl;
    // Note: acc is a running sum. Expected values accumulate.
    // 2*3 = 6 (acc = 0 + 6)
    run_one(dut, pack(2, 0, 0, 0), pack(3, 0, 0, 0), 6);
    // sum of all lanes: 1+4+9+16 = 30 (acc = 6 + 30 = 36)
    run_one(dut, pack(1, 2, 3, 4), pack(1, 2, 3, 4), 36);
    // negative: -2 * 3 = -6 (acc = 36 + (-6) = 30)
    run_one(dut, pack(-2, 0, 0, 0), pack(3, 0, 0, 0), (uint32_t)30);

    std::cout << (failures == 0 ? "ALL SIMD MAC TESTS PASSED" : "SIMD MAC TESTS FAILED") << std::endl;
    delete dut;
    return failures == 0 ? 0 : 1;
}
