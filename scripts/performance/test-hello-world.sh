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
    echo "Checked:"
    echo "  - $PROJECT_ROOT/generated/linux/release/64/dmd"
    echo "  - $PROJECT_ROOT/generated/linux/debug/64/dmd"
    echo "  - dmd in PATH"
    exit 1
fi

echo "Using DMD: $DMD_CMD"

# Create temporary directory for hello world test
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Create hello world program
cat > hello.d << 'EOF'
import std.stdio;

void main() {
    writeln("Hello, World!");
}
EOF

# Test compilation time
echo "Compiling Hello World..."
start_time=$(date +%s.%N)
"$DMD_CMD" hello.d -of=hello
end_time=$(date +%s.%N)
compile_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")

# Measure binary size
if [ -f "hello" ]; then
    binary_size=$(stat -c%s "hello")
else
    binary_size=0
fi

# Test with different flags
start_time=$(date +%s.%N)
"$DMD_CMD" hello.d -O -release -of=hello_optimized
end_time=$(date +%s.%N)
optimized_compile_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")

optimized_binary_size=0
if [ -f "hello_optimized" ]; then
    optimized_binary_size=$(stat -c%s "hello_optimized")
fi

# Write results
cd "$PROJECT_ROOT"
cat >> "$RESULTS_DIR/results.json" << EOF
  "hello_world": {
    "compile_time_seconds": $compile_time,
    "binary_size_bytes": $binary_size,
    "optimized_compile_time_seconds": $optimized_compile_time,
    "optimized_binary_size_bytes": $optimized_binary_size
  },
EOF

echo "Hello World - Compile: ${compile_time}s, Size: ${binary_size} bytes"
echo "Hello World Optimized - Compile: ${optimized_compile_time}s, Size: ${optimized_binary_size} bytes"

# Cleanup
rm -rf "$TEMP_DIR"