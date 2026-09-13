# Common build rules for X-HEEP bare-metal test programs.
# Included by sw/platforms/xheep/tests/*/Makefile (two directories below common/).
#
# Toolchain resolution: override with RISCV_PREFIX=/path/to/bin/riscv-none-elf- (trailing dash)
# if the toolchain isn't on PATH, e.g.:
#   make RISCV_PREFIX=/opt/riscv-none-elf-gcc/bin/riscv-none-elf-
RISCV_PREFIX ?= riscv-none-elf-
CC := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy

ifeq ($(shell command -v $(CC) 2>/dev/null),)
$(error RISC-V toolchain not found: '$(CC)' is not on PATH. \
Install a riscv-none-elf-gcc toolchain (e.g. the xPack RISC-V toolchain) and add it to PATH, \
or point at it directly with: make RISCV_PREFIX=/path/to/bin/riscv-none-elf-)
endif

CFLAGS = -march=rv32imc_zicsr -mabi=ilp32 -O2 -nostdlib -ffreestanding
LDFLAGS = -T ../../common/link.ld -nostdlib -ffreestanding

%.elf: ../../common/start.S %.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

%.bin: %.elf
	$(OBJCOPY) -O binary $< $@

%.hex: %.bin
	hexdump -v -e '1/4 "%08x\n"' $< > $@

clean:
	rm -f *.elf *.bin *.hex
