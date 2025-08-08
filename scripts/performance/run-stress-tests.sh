#!/bin/bash
set -e

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
else
    # Using system DMD, no special flags needed
    DMD_FLAGS=""
fi

echo "Running stress tests..."

STRESS_DIR="$PROJECT_ROOT/stress-tests"
TEMP_DIR=$(mktemp -d)

# Template stress test
echo "Testing template-heavy compilation..."
start_time=$(date +%s.%N)
timeout 300 bash -c "$DMD_CMD $DMD_FLAGS '$STRESS_DIR/template-stress.d' -of='$TEMP_DIR/template-test'" || echo "Template test completed/timed out"
end_time=$(date +%s.%N)
template_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")

# CTFE stress test
echo "Testing CTFE-heavy compilation..."
start_time=$(date +%s.%N)
timeout 300 bash -c "$DMD_CMD $DMD_FLAGS '$STRESS_DIR/ctfe-stress.d' -of='$TEMP_DIR/ctfe-test'" || echo "CTFE test completed/timed out"
end_time=$(date +%s.%N)
ctfe_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")

# Write stress test results
cat >> "$RESULTS_DIR/results.json" << EOF
  "stress_tests": {
    "template_stress_compile_time": $template_time,
    "ctfe_stress_compile_time": $ctfe_time
  },
EOF

echo "Template stress test: ${template_time}s"
echo "CTFE stress test: ${ctfe_time}s"

# Cleanup
rm -rf "$TEMP_DIR"