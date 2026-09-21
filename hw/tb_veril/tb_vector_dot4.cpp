// tb_vector_dot4.cpp
//
// Verilator testbench for the auto-generated vector_dot4 datapath
// (examples/vector_dot4.jl):
//   dot4(a, b) = a0*b0 + a1*b1 + a2*b2 + a3*b3
//
// Unlike the standard 2-operand HWExplore datapath contract (rs1_i/rs2_i),
// this module has 8 scalar inputs (rs1_i..rs8_i = a0,a1,a2,a3,b0,b1,b2,b3),
// so it's tested standalone here rather than through the CV-X-IF dispatch
// path, which only ever forwards two operands per instruction. See
// docs/Usage_and_Examples.md for why that's a real, worth-knowing limit,
// not an oversight.

// DUT module name is a compile-time macro so the same testbench checks the
// plain and the resource-shared variants: -CFLAGS -DDUT=vector_dot4_shared_2
#ifndef DUT
#define DUT vector_dot4
#endif
#define STR_(x) #x
#define STR(x) STR_(x)
#define CAT_(a, b) a##b
#define CAT(a, b) CAT_(a, b)
#include STR(CAT(V, DUT).h)
#include "verilated.h"
#include <cstdint>
#include <iostream>

static vluint64_t sim_time = 0;
double sc_time_stamp() { return sim_time; }

static void tick(CAT(V, DUT)* dut) {
    dut->clk_i = 0; dut->eval(); sim_time++;
    dut->clk_i = 1; dut->eval(); sim_time++;
}

struct Vec4 { int32_t a0, a1, a2, a3, b0, b1, b2, b3; };

static bool run_case(CAT(V, DUT)* dut, const Vec4& v, int32_t expected) {
    dut->rs1_i = v.a0; dut->rs2_i = v.a1; dut->rs3_i = v.a2; dut->rs4_i = v.a3;
    dut->rs5_i = v.b0; dut->rs6_i = v.b1; dut->rs7_i = v.b2; dut->rs8_i = v.b3;
    dut->start_i = 1;
    tick(dut);
    dut->start_i = 0;
#ifdef SCRAMBLE
    // Operands are only guaranteed valid in the start cycle: scramble them so
    // the resource-shared variants prove they latch what they need (rs*_q).
    // (The plain emitter's pipeline chains need rs*_i held stable to done_o.)
    dut->rs1_i = 0x5a5a5a5a; dut->rs2_i = 0xa5a5a5a5; dut->rs3_i = 0x0f0f0f0f; dut->rs4_i = 0xf0f0f0f0;
    dut->rs5_i = 0x12345678; dut->rs6_i = 0x87654321; dut->rs7_i = 0xdeadbeef; dut->rs8_i = 0xcafef00d;
#endif

    int timeout = 60;   // shared variants serialize the multiplies: latency grows
    while (!dut->done_o && timeout-- > 0) tick(dut);

    if (!dut->done_o) {
        std::cout << "  [FAIL] timed out waiting for done_o" << std::endl;
        return false;
    }
    int32_t got = (int32_t)dut->rd_o;
    bool ok = (got == expected);
    std::cout << "  [" << (ok ? "PASS" : "FAIL") << "] dot4 = " << got
               << "  (expected " << expected << ")" << std::endl;
    return ok;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    CAT(V, DUT)* dut = new CAT(V, DUT);

    dut->rst_ni = 0; dut->start_i = 0; dut->stall_i = 0;
    dut->rs1_i = 0; dut->rs2_i = 0; dut->rs3_i = 0; dut->rs4_i = 0;
    dut->rs5_i = 0; dut->rs6_i = 0; dut->rs7_i = 0; dut->rs8_i = 0;
    tick(dut); tick(dut);
    dut->rst_ni = 1;

    std::cout << "Vector dot4 tests: dot4(a,b) = a0*b0 + a1*b1 + a2*b2 + a3*b3" << std::endl;

    bool all_ok = true;
    // a = (1,2,3,4), b = (5,6,7,8) -> 1*5+2*6+3*7+4*8 = 5+12+21+32 = 70
    all_ok &= run_case(dut, {1, 2, 3, 4, 5, 6, 7, 8}, 70);
    // a = (0,0,0,0), b = (anything) -> 0
    all_ok &= run_case(dut, {0, 0, 0, 0, 9, 9, 9, 9}, 0);
    // a = (1,1,1,1), b = (1,1,1,1) -> 4
    all_ok &= run_case(dut, {1, 1, 1, 1, 1, 1, 1, 1}, 4);
    // negative values: a = (-1,2,-3,4), b = (1,1,1,1) -> -1+2-3+4 = 2
    all_ok &= run_case(dut, {-1, 2, -3, 4, 1, 1, 1, 1}, 2);
    // back-to-back start (no gap between issues) to check the pipeline
    // drains/restarts correctly rather than only being tested cold
    all_ok &= run_case(dut, {2, 2, 2, 2, 3, 3, 3, 3}, 24);

    std::cout << (all_ok ? "ALL VECTOR DOT4 TESTS PASSED" : "SOME VECTOR DOT4 TESTS FAILED") << std::endl;

    delete dut;
    return all_ok ? 0 : 1;
}
