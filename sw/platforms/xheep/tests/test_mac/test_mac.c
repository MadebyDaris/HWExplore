#include <stdint.h>

// A simple function to invoke the custom CV-X-IF coprocessor
// For mac_plus_5, it expects CUSTOM_0 with rs1 and rs2.
static inline uint32_t mac_plus_5(uint32_t rs1, uint32_t rs2) {
    uint32_t rd;
    // R-type format for CUSTOM_0 (opcode 0x0B).
    // funct3 = 3 (mac_plus_5 is the stateless datapath registered at funct3=3
    // in scripts/build_manifest.jl; funct3 0-2 are reserved for the stateful
    // command encoding, not mac_plus_5).
    asm volatile (
        ".insn r 0x0B, 3, 0, %0, %1, %2"
        : "=r" (rd)
        : "r" (rs1), "r" (rs2)
    );
    return rd;
}

#define EXIT_ADDR 0xF0000000

int main() {
    uint32_t result = mac_plus_5(3, 4); // 3 * 4 + 5 = 17

    uint32_t status = (result == 17) ? 1 : 2; // 1 for success, 2 for failure

    // Write to exit address
    volatile uint32_t* exit_reg = (volatile uint32_t*)EXIT_ADDR;
    *exit_reg = status;
    
    while(1) {
        asm volatile("wfi");
    }
    
    return 0;
}
