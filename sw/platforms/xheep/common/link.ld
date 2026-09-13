OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    ram (rwx) : ORIGIN = 0x00000000, LENGTH = 0x8000 /* Boot address default is 0x180 */
}

SECTIONS {
    .text : {
        *(.text.start)
        *(.text)
        *(.text.*)
    } > ram

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    } > ram

    .data : {
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    } > ram

    .bss : {
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        __bss_end = .;
    } > ram
}
