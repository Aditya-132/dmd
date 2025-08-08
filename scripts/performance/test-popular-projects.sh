#!/bin/bash

# Helper function to format duration with leading zero
format_duration() {
    local duration="$1"
    printf "%.9f" "$duration" | sed 's/^\./0./'
}

# Get the DMD binary path
if [ -f "$PROJECT_ROOT/generated/linux/release/64/dmd" ]; then
    DMD_CMD="$PROJECT_ROOT/generated/linux/release/64/dmd"
elif [ -f "$PROJECT_ROOT/generated/linux/debug/64/dmd" ]; then
    DMD_CMD="$PROJECT_ROOT/generated/linux/debug/64/dmd"
elif command -v dmd &> /dev/null; then
    DMD_CMD="dmd"
else
    echo "Error: DMD compiler not found!"
    exit 1
fi

echo "Using DMD: $DMD_CMD"

# Set up library paths for locally built DMD
if [[ "$DMD_CMD" == *"$PROJECT_ROOT"* ]]; then
    # Using locally built DMD, need to specify library paths
    DRUNTIME_PATH="$PROJECT_ROOT/druntime/import"
    
    # Look for Phobos in common locations
    if [ -d "/home/aditya/phobos" ]; then
        PHOBOS_PATH="/home/aditya/phobos"
    elif [ -d "$PROJECT_ROOT/../phobos" ]; then
        PHOBOS_PATH="$PROJECT_ROOT/../phobos"
    elif [ -d "$PROJECT_ROOT/../../phobos" ]; then
        PHOBOS_PATH="$PROJECT_ROOT/../../phobos"
    else
        echo "Error: Cannot find Phobos directory!"
        echo "Please clone Phobos: git clone https://github.com/dlang/phobos.git"
        exit 1
    fi
    
    # Set up the library path for linking
    PHOBOS_LIB_PATH="$PHOBOS_PATH/generated/linux/release/64"
    if [ ! -d "$PHOBOS_LIB_PATH" ]; then
        echo "Error: Phobos library not built. Run 'make' in $PHOBOS_PATH"
        exit 1
    fi
    
    DMD_FLAGS="-I$PHOBOS_PATH -I$DRUNTIME_PATH -L-L$PHOBOS_LIB_PATH"
    
    echo "Using local libraries:"
    echo "  Phobos: $PHOBOS_PATH"
    echo "  Druntime: $DRUNTIME_PATH"
    echo "  Phobos lib: $PHOBOS_LIB_PATH"
else
    # Using system DMD, no special flags needed
    DMD_FLAGS=""
fi

echo "DMD flags: $DMD_FLAGS"

# Test compilation of a medium-sized D program
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Create a more complex test program that exercises various D features
cat > complex_test.d << 'EOF'
import std.stdio;
import std.algorithm;
import std.range;
import std.conv;
import std.string;
import std.array;
import std.typecons;

// Template heavy code
template Fibonacci(uint n) {
    static if (n <= 1)
        enum Fibonacci = n;
    else
        enum Fibonacci = Fibonacci!(n-1) + Fibonacci!(n-2);
}

// CTFE function
string generateArrayCode(int size) {
    string result = "int[] testArray = [";
    foreach (i; 0..size) {
        if (i > 0) result ~= ", ";
        result ~= i.to!string;
    }
    result ~= "];";
    return result;
}

// Mixin template
mixin template CommonOperations() {
    void process(T)(T[] data) {
        auto result = data.filter!(x => x > 0)
                         .map!(x => x * 2)
                         .array;
        writeln("Processed: ", result);
    }
}

class TestClass {
    mixin CommonOperations;
    
    private int[] data;
    
    this(int[] initialData) {
        data = initialData;
    }
    
    void run() {
        process(data);
    }
}

void main() {
    // Use compile-time computation
    enum fib10 = Fibonacci!10;
    writeln("Fibonacci 10: ", fib10);
    
    // Use CTFE
    mixin(generateArrayCode(100));
    writeln("Array length: ", testArray.length);
    
    // Use template and class
    auto obj = new TestClass([1, -2, 3, -4, 5]);
    obj.run();
    
    // Use ranges and algorithms
    auto numbers = iota(1, 1000)
                  .filter!(x => x % 2 == 0)
                  .map!(x => x ^^ 2)
                  .take(10)
                  .array;
    writeln("Even squares: ", numbers);
}
EOF

# Compile and measure
echo "Compiling complex test program..."
start_time=$(date +%s.%N)
$DMD_CMD $DMD_FLAGS complex_test.d -of=complex_test
compilation_result=$?
end_time=$(date +%s.%N)
complex_compile_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")

if [ $compilation_result -ne 0 ]; then
    echo "Complex test compilation failed!"
    echo "Debug info:"
    echo "Command run: $DMD_CMD $DMD_FLAGS complex_test.d -of=complex_test"
    cd "$PROJECT_ROOT"
    rm -rf "$TEMP_DIR"
    # Don't exit - just set empty results
    complex_binary_size=0
    complex_compile_time="0.000000000"
else
    complex_binary_size=0
    if [ -f "complex_test" ]; then
        complex_binary_size=$(stat -c%s "complex_test")
        echo "Testing complex binary execution..."
        ./complex_test && echo "✓ Complex binary executed successfully" || echo "✗ Complex binary execution failed"
    fi
fi

# Cleanup and return
cd "$PROJECT_ROOT"
rm -rf "$TEMP_DIR"

# Write results
cat >> "$RESULTS_DIR/results.json" << EOF
  "complex_project": {
    "compile_time_seconds": $complex_compile_time,
    "binary_size_bytes": $complex_binary_size
  },
EOF

echo "Complex project - Compile: ${complex_compile_time}s, Size: ${complex_binary_size} bytes"