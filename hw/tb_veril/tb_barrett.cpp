// tb_barrett.cpp — standalone Barrett reduction test
#include <iostream>
#include <verilated.h>
#include "Vhwx_barrett_reduction.h"

static int failures = 0;

static void check(const char* name, uint32_t got, uint32_t expected) {
    if (got == expected) {
        std::cout << "  [PASS] " << name << " = " << got << std::endl;
    } else {
        std::cout << "  [FAIL] " << name << " = " << got << " (expected " << expected << ")" << std::endl;
        failures++;
    }
}

static void run_one(Vhwx_barrett_reduction* dut, uint32_t x, uint32_t expected) {
    dut->rs1_i = x;
    dut->rs2_i = 0;
    dut->start_i = 1;
    dut->stall_i = 0;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->start_i = 0;

    // Wait up to 10 cycles for done
    int cycles = 0;
    while (!dut->done_o && cycles++ < 10) {
        dut->clk_i = 0; dut->eval();
        dut->clk_i = 1; dut->eval();
    }
    char name[64];
    snprintf(name, sizeof(name), "barrett(%u)", x);
    check(name, dut->rd_o, expected);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vhwx_barrett_reduction* dut = new Vhwx_barrett_reduction;

    dut->rst_ni = 0;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval();
    dut->rst_ni = 1;

    std::cout << "Barrett reduction tests (MODULUS=12289, K=349496):" << std::endl;
    run_one(dut, 0, 0);
    run_one(dut, 1, 1);
    run_one(dut, 12288, 12288);
    run_one(dut, 12289, 0);
    run_one(dut, 12290, 1);
    run_one(dut, 24578, 0);
    run_one(dut, 0xDEADBEEF, 0xDEADBEEF % 12289);
    run_one(dut, 0x7FFFFFFF, 0x7FFFFFFF % 12289);

    std::cout << (failures == 0 ? "ALL BARRETT TESTS PASSED" : "BARRETT TESTS FAILED") << std::endl;
    delete dut;
    return failures == 0 ? 0 : 1;
}
