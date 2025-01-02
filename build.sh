if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <source.asm>"
    exit 1
fi

SOURCE_FILE=$1
BASE_NAME=$(basename "$SOURCE_FILE" .asm)

if [ ! -f "$SOURCE_FILE" ]; then
    echo "Error: File '$SOURCE_FILE' not found."
    exit 1
fi

echo "Assembling $SOURCE_FILE..."

nasm -f elf64 "$SOURCE_FILE" -o "$BASE_NAME.o"
if [ $? -ne 0 ]; then
    echo "Error: NASM failed."
    exit 1
fi

echo "Linking $BASE_NAME.o..."

ld "$BASE_NAME.o" -o "$BASE_NAME"
if [ $? -ne 0 ]; then
    echo "Error: Linking failed."
    exit 1
fi

echo "Build successful. Output -> $BASE_NAME"

# Run the executable
echo "Running $BASE_NAME..."

echo "================="
echo " "

./"$BASE_NAME"
RUN_STATUS=$?

# Clean up generated files
echo " "
echo "================="

rm -f "$BASE_NAME.o" "$BASE_NAME"
if [ $? -eq 0 ]; then
    echo "Cleanup successful."
else
    echo "Error: Cleanup failed."
fi

exit $RUN_STATUS
