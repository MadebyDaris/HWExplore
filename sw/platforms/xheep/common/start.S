.section .text.start
.global _start
_start:
    // Initialize stack pointer (top of SRAM, e.g. 0x00008000)
    li sp, 0x00008000
    call main
    
    // Fallback if main returns
    li a0, 0x80000000
    li a1, 3
    sw a1, 0(a0)
1:  j 1b
