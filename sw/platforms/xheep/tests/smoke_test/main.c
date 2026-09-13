/*
 * main.c — HWExplore PoC bare-metal smoke test
 *
 * Cycles through all 4 standard funct3 datapaths and verifies results.
 *
 * Custom instruction encoding (opcode 0x0B = custom-0):
 *   .insn r CUSTOM_0, funct3, rd, rs1, rs2
 *
 * funct3 map (updated by DispatcherEmitter with stateful paths):
 *   0 → CMD_WRITE_ADDR
 *   1 → CMD_WRITE_DATA
 *   2 → CMD_START
 *   3 → mac_plus_5      (rs1 * rs2) + 5
 *   4 → crc_step         (data >> 1) ^ (POLY if LSB else 0)
 *   5 → hwx_simd_mac   4x8-bit SIMD multiply-accumulate
 *   6 → hwx_saturating_add  4x8-bit saturating signed add
 *   7 → hwx_barrett_reduction
 */

#define EXIT_SUCCESS_ADDR ((volatile int*)0xF0000000)
#define EXIT_FAILURE_ADDR ((volatile int*)0xF0000004)

// ── Custom instruction wrappers ──────────────────────────────────────────────

static inline int hwx_call(int funct3, int rs1, int rs2) {
    int result;
    asm volatile (
        ".insn r 0x0B, %[f3], %[f7], %[rd], %[rs1], %[rs2]\n\t"
        : [rd] "=r" (result)
        : [f3] "i" (funct3), [f7] "i" (0),
          [rs1] "r" (rs1), [rs2] "r" (rs2)
    );
    return result;
}

// ── Test helpers ─────────────────────────────────────────────────────────────

static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name, cond) do {                              \
    if (cond) {                                            \
        tests_passed++;                                    \
    } else {                                               \
        tests_failed++;                                    \
        *EXIT_SUCCESS_ADDR = __LINE__ << 1;                \
    }                                                      \
} while(0)

// ── Main ─────────────────────────────────────────────────────────────────────

int main(void) {
    int result;

    // Test 1: funct3=3 — mac_plus_5: (rs1 * rs2) + 5
    result = hwx_call(3, 3, 4);
    TEST("mac_plus_5 (3*4+5)", result == 17);

    // Test 2: funct3=4 — crc_step
    // For data=0x00000001 (odd, LSB=1): (1>>1) ^ POLY = 0 ^ 0x04C11DB7 = 0x04C11DB7
    result = hwx_call(4, 1, 0);
    TEST("crc_step (data=1, LSB=1)", result == 0x04C11DB7);

    // Test 3: funct3=5 — hwx_simd_mac (4x8-bit SIMD MAC)
    // Packed: rs1 = {0,0,0,2}, rs2 = {0,0,0,3} → 2*3 = 6
    result = hwx_call(5, 0x00000002, 0x00000003);
    TEST("simd_mac (2*3)", result == 6);

    // Test 4: funct3=6 — hwx_saturating_add (4x8-bit)
    // Packed: rs1 = 0x7F010101 (127,1,1,1), rs2 = 0x01010101 (1,1,1,1)
    // Lane 0: 127+1=128 → saturates to 127
    // Lane 1: 1+1=2
    // Expected: 0x7F020202
    result = hwx_call(6, 0x7F010101, 0x01010101);
    TEST("saturating_add", result == 0x7F020202);

    // Summary
    if (tests_failed == 0) {
        *EXIT_SUCCESS_ADDR = 1; // 1 means success
    } else {
        *EXIT_SUCCESS_ADDR = (tests_failed << 1); // non-1 means failure
    }

    while (1) {}
    return 0;
}