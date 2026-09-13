#include <iostream>
#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vtb_hwx_system.h"

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

int main(int argc, char** argv, char** env) {
    Verilated::commandArgs(argc, argv);
    Vtb_hwx_system* top = new Vtb_hwx_system;
    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("sim.vcd");

    // Apply reset, toggle clock
    top->clk_i = 0;
    top->rst_ni = 0;
    top->eval();
    for (int i = 0; i < 20; i++) {
        top->clk_i = !top->clk_i;
        top->eval();
        tfp->dump(main_time++);
    }

    // Release reset on negative edge (clk=0)
    top->clk_i = 0;
    top->rst_ni = 1;
    top->eval();
    tfp->dump(main_time++);

    // Run
    bool ok = false;
    uint32_t val = 0;
    int c = 0;
    while (!Verilated::gotFinish() && c++ < 500000) {
        top->clk_i = !top->clk_i;
        top->eval();
        tfp->dump(main_time++);
        if (top->clk_i && top->exit_valid_o) { ok = true; val = top->exit_value_o; break; }
    }

    if (ok) std::cout << (val==1?"EXIT SUCCESS":"EXIT FAILURE") << std::endl;
    else std::cout << "TIMEOUT" << std::endl;
    top->final(); tfp->close(); delete tfp; delete top;
    return ok ? 0 : 1;
}
