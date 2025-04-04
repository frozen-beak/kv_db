ASM = nasm
LD = ld
ASMFLAGS = -f elf64
DEBUGFLAGS = -g -F dwarf
TARGET = server
SRC = server.asm
OBJ = server.o

# Default: clean first, then build
all: clean $(TARGET)

# Link using ld
$(TARGET): $(OBJ)
	$(LD) -o $@ $<

# Assemble using nasm
$(OBJ): $(SRC)
	$(ASM) $(ASMFLAGS) -o $@ $<

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(OBJ) $(TARGET)
