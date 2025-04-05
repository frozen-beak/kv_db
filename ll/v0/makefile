ASM = nasm -f elf64
LD = ld
DEBUG = -g -F dwarf
TARGET = ll
SRC = ll.asm
OBJ = ll.o

# build src file using `nasm`
$(OBJ): $(SRC)
	$(ASM) $< -o $@

# link src file using `ld`
$(TARGET): $(OBJ)
	$(LD) -o $@ $^

# build src
build: $(TARGET)

# Build w/ debug info
debug:
	$(ASM) $(DEBUG) $(SRC) -o $(OBJ)
	$(LD) -o $(TARGET) $(OBJ)

# execute build files
run:
	@if [ -f $(TARGET) ]; then \
		./$(TARGET); \
	else \
		echo "$(TARGET) not built. Run 'make build' first."; \
		exit 1; \
	fi

# clean build files
clean:
	rm -rf $(OBJ) $(TARGET)
