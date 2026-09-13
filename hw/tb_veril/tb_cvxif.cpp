// tb_cvxif.cpp
//
// Verilator testbench for cvxif_hwx_shell.
// Tests: issue -> commit -> result handshake.
// The shell now instantiates mac_plus_5: (rs1 * rs2) + 5, 4-cycle latency.
//   rs1=10, rs2=20 => expected result = (10*20)+5 = 205

#include "Vcvxif_hwx_shell.h"
#include "verilated.h"
#include <iostream>
#include <cassert>

static vluint64_t sim_time = 0;

double sc_time_stamp() { return sim_time; } // Called by $time in Verilog


static int dp_timer = 0;
static bool dp_running = false;

static void tick(Vcvxif_hwx_shell* dut) {
    dut->clk_i = 0; 
    dut->eval(); 
    sim_time++;

    if (dut->dp_start_o && !dp_running) {
        dp_running = true;
        dp_timer = 4; // 4 cycle latency
    }
    
    if (dp_running && !dut->stall_i) { // assume datapath respects stall
        if (dp_timer > 0) dp_timer--;
    }
    
    if (dp_running && dp_timer == 0) {
        dut->dp_done_i = 1;
        dut->dp_rd_i = (dut->dp_rs1_o * dut->dp_rs2_o) + 5;
        dp_running = false;
    } else {
        dut->dp_done_i = 0;
    }

    dut->clk_i = 1; 
    dut->eval(); 
    sim_time++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vcvxif_hwx_shell* dut = new Vcvxif_hwx_shell;

    bool test_pass = true;

    // Initialise all inputs
    dut->clk_i               = 0;
    dut->rst_ni              = 0;
    dut->stall_i             = 0;
    dut->x_issue_req_valid_i = 0;
    dut->x_issue_req_instr_i = 0;
    dut->x_issue_req_rs1_i   = 0;
    dut->x_issue_req_rs2_i   = 0;
    dut->x_issue_req_id_i    = 0;
    dut->x_commit_valid_i    = 0;
    dut->x_commit_id_i       = 0;
    dut->x_commit_kill_i     = 0;
    dut->x_result_ready_i    = 1;

    // Reset for 2 cycles
    tick(dut);
    tick(dut);
    dut->rst_ni = 1;
    tick(dut);

    // Normal flow issue, commit, get result
    std::cout << "--- Test 1: Normal issue/commit/result ---" << std::endl;

    // remember that the custom instruction is R-type, opcode=0x0B, rd=x1, rs1=x1, rs2=x2
    // CUSTOM_0 R-type: opcode=0x0B, rd=x1, rs1=x1, rs2=x2
    uint32_t instr = (0x0 << 25) | (2 << 20) | (1 << 15) | (0 << 12) | (1 << 7) | 0x0B;

    dut->x_issue_req_valid_i = 1; // send instruction
    dut->x_issue_req_instr_i = instr;
    dut->x_issue_req_rs1_i   = 10;
    dut->x_issue_req_rs2_i   = 20;
    dut->x_issue_req_id_i    = 1; // CPU will use this ID to match the result
    dut->clk_i = 0; dut->eval();

    if (dut->x_issue_resp_valid_o && dut->x_issue_resp_accept_o)
        std::cout << "  Issue accepted (ID=" << (int)dut->x_issue_resp_id_o << ")" << std::endl;
    else {
        std::cout << "  Issue NOT accepted -- FAIL" << std::endl;
        test_pass = false;
    }
    dut->clk_i = 1; dut->eval(); sim_time++;

    dut->x_issue_req_valid_i = 0;
    tick(dut); // settle into WAIT_COMMIT

    // Send commit
    dut->x_commit_valid_i = 1;
    dut->x_commit_id_i    = 1;
    dut->x_commit_kill_i  = 0;
    tick(dut);
    dut->x_commit_valid_i = 0;

    // Inject stall mid-computation to prove datapath resumes cleanly
    std::cout << "  Injecting stall for 3 cycles..." << std::endl;
    dut->stall_i = 1;
    tick(dut);
    tick(dut);
    tick(dut);
    dut->stall_i = 0;

    // Wait for result (poll up to 15 cycles)
    int timeout = 15;
    while (!dut->x_result_valid_o && timeout-- > 0)
        tick(dut);

    if (dut->x_result_valid_o) {
        std::cout << "  Result valid, data = " << dut->x_result_data_o
                  << "  (expected 205)" << std::endl;
        if (dut->x_result_data_o == 205)
            std::cout << "  Test 1: PASS" << std::endl;
        else {
            std::cout << "  Test 1: FAIL (wrong value)" << std::endl;
            test_pass = false;
        }
    } else {
        std::cout << "  Timeout -- Test 1: FAIL" << std::endl;
        test_pass = false;
    }
    tick(dut); // CPU accepts result

    // Kill (branch mispredict) shell must return to IDLE
    // assert that the shell is back in IDLE by issuing another instruction and checking ready signal
    std::cout << "\n--- Test 2: Kill (mispredict) ---" << std::endl;

    dut->x_issue_req_valid_i = 1;
    dut->x_issue_req_instr_i = instr;
    dut->x_issue_req_rs1_i   = 5;
    dut->x_issue_req_rs2_i   = 5;
    dut->x_issue_req_id_i    = 2;
    dut->clk_i = 0; dut->eval();
    dut->clk_i = 1; dut->eval(); sim_time++;
    dut->x_issue_req_valid_i = 0;
    tick(dut);

    dut->x_commit_valid_i = 1;
    dut->x_commit_id_i    = 2;
    dut->x_commit_kill_i  = 1;  // Kill signal
    tick(dut);
    dut->x_commit_valid_i = 0;
    tick(dut);

    // Shell should be back in IDLE
    dut->x_issue_req_valid_i = 1;
    dut->x_issue_req_instr_i = instr;
    dut->x_issue_req_id_i    = 3;
    dut->clk_i = 0; dut->eval();

    if (dut->x_issue_req_ready_o)
        std::cout << "  Shell back in IDLE after kill: PASS" << std::endl;
    else {
        std::cout << "  Shell not ready after kill: FAIL" << std::endl;
        test_pass = false;
    }
    dut->clk_i = 1; dut->eval(); sim_time++;
    dut->x_issue_req_valid_i = 0;

    std::cout << "\n=== " << (test_pass ? "ALL TESTS PASSED" : "SOME TESTS FAILED") << " ===" << std::endl;

    delete dut;
    return test_pass ? 0 : 1;
}
