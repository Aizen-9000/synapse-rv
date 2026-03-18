# =============================================================================
#  Synapse-RV Software Build — Makefile
# =============================================================================
CROSS   = riscv64-unknown-elf
CC      = $(CROSS)-gcc
OBJCOPY = $(CROSS)-objcopy
OBJDUMP = $(CROSS)-objdump
SIZE    = $(CROSS)-size

ARCH    = rv64gc
ABI     = lp64d
CFLAGS  = -march=$(ARCH) -mabi=$(ABI) -O2 -mcmodel=medany -Wall -ffreestanding -fno-builtin -nostdlib \
          -I drivers -I runtime
LDFLAGS = -T linker.ld -nostdlib

BUILD   = build
TARGET  = $(BUILD)/synapse_rv_fw

SRCS_C  = drivers/npu_driver.c runtime/inference.c runtime/main.c
SRCS_S  = bootloader/bootloader.S
OBJS    = $(SRCS_C:%.c=$(BUILD)/%.o) $(SRCS_S:%.S=$(BUILD)/%.o)

.PHONY: all clean rom_hex disasm size

all: $(TARGET).elf $(TARGET).bin $(TARGET).hex disasm size

$(BUILD)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: %.S
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET).elf: $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@

$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

$(TARGET).hex: $(TARGET).elf
	$(OBJCOPY) -O ihex $< $@

rom_hex: $(TARGET).bin
	python3 scripts/bin2hex.py $(TARGET).bin ../build/boot_rom.hex

disasm: $(TARGET).elf
	$(OBJDUMP) -d -S $< > $(BUILD)/synapse_rv_fw.lst

size: $(TARGET).elf
	$(SIZE) -A $(TARGET).elf

clean:
	rm -rf $(BUILD)

qemu: $(TARGET).elf
	qemu-system-riscv64 -machine virt -nographic -bios none -kernel $< -serial mon:stdio
