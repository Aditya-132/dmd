#!/bin/bash
set -e

# Helper function to format duration with leading zero
format_duration() {
    local duration="$1"
    printf "%.9f" "$duration" | sed 's/^\./0./'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="$PROJECT_ROOT/perf-results"

# Export variables for sourced scripts
export PROJECT_ROOT
export RESULTS_DIR
export -f format_duration

# Ensure results directory exists
mkdir -p "$RESULTS_DIR"

# Initialize results file with proper Git info
echo "{" > "$RESULTS_DIR/results.json"
echo "  \"timestamp\": \"$(date -Iseconds)\"," >> "$RESULTS_DIR/results.json"

# Get git info - handle cases where we might not be in a git repo
if git rev-parse --git-dir > /dev/null 2>&1; then
    echo "  \"commit\": \"$(git rev-parse HEAD)\"," >> "$RESULTS_DIR/results.json"
    echo "  \"branch\": \"$(git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')\"," >> "$RESULTS_DIR/results.json"
else
    echo "  \"commit\": \"unknown\"," >> "$RESULTS_DIR/results.json"
    echo "  \"branch\": \"unknown\"," >> "$RESULTS_DIR/results.json"
fi

echo "Starting Performance Regression Tests for DMD..."
echo "Project root: $PROJECT_ROOT"
echo "Results directory: $RESULTS_DIR"

# Check if we're in a DMD repository
if [ ! -f "$PROJECT_ROOT/src/dmd/mars.d" ] && [ ! -f "$PROJECT_ROOT/mars.d" ]; then
    echo "Warning: This doesn't appear to be a DMD repository"
    echo "Looking for src/dmd/mars.d or mars.d in $PROJECT_ROOT"
fi

# Test 1: Test Suite Runtime
echo "Running DMD test suite timing..."
cd "$PROJECT_ROOT"

# DMD uses different test commands depending on setup
start_time=$(date +%s.%N)
if [ -f "Makefile" ]; then
    echo "Using Makefile for tests..."
    timeout 1800 make test > /dev/null 2>&1 || echo "Test suite completed/timed out"
elif [ -f "dub.json" ] || [ -f "dub.sdl" ]; then
    echo "Using dub for tests..."
    timeout 1800 dub test > /dev/null 2>&1 || echo "Test suite completed/timed out"
elif [ -d "test" ]; then
    echo "Running tests from test directory..."
    cd test
    timeout 1800 make > /dev/null 2>&1 || echo "Test suite completed/timed out"
    cd "$PROJECT_ROOT"
else
    echo "No standard test setup found, skipping test suite timing"
    start_time=$(date +%s.%N)  # Reset to current time for zero duration
fi
end_time=$(date +%s.%N)
test_duration=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")
echo "  \"test_suite_duration\": $test_duration," >> "$RESULTS_DIR/results.json"

# Test 2: Hello World and Popular Projects
if [ -f "$SCRIPT_DIR/test-hello-world.sh" ]; then
    echo "Running hello world tests..."
    source "$SCRIPT_DIR/test-hello-world.sh"
else
    echo "Skipping hello world tests - script not found"
    echo "  \"hello_world\": {" >> "$RESULTS_DIR/results.json"
    echo "    \"compile_time_seconds\": 0.000000000," >> "$RESULTS_DIR/results.json"
    echo "    \"binary_size_bytes\": 0," >> "$RESULTS_DIR/results.json"
    echo "    \"optimized_compile_time_seconds\": 0.000000000," >> "$RESULTS_DIR/results.json"
    echo "    \"optimized_binary_size_bytes\": 0" >> "$RESULTS_DIR/results.json"
    echo "  }," >> "$RESULTS_DIR/results.json"
fi

if [ -f "$SCRIPT_DIR/test-popular-projects.sh" ]; then
    echo "Running complex project tests..."
    source "$SCRIPT_DIR/test-popular-projects.sh"
else
    echo "Skipping complex project tests - script not found"
    echo "  \"complex_project\": {" >> "$RESULTS_DIR/results.json"
    echo "    \"compile_time_seconds\": 0.000000000," >> "$RESULTS_DIR/results.json"
    echo "    \"binary_size_bytes\": 0" >> "$RESULTS_DIR/results.json"
    echo "  }," >> "$RESULTS_DIR/results.json"
fi

# Test 3: Compiler Size - check multiple possible locations
echo "Checking compiler binary size..."
compiler_size=0
DMD_BINARY=""

# Common DMD binary locations
POSSIBLE_LOCATIONS=(
    "generated/linux/release/64/dmd"
    "generated/linux/debug/64/dmd"
    "generated/osx/release/64/dmd"
    "generated/windows/release/64/dmd.exe"
    "src/dmd"
    "dmd"
    "bin/dmd"
    "build/dmd"
)

cd "$PROJECT_ROOT"
for location in "${POSSIBLE_LOCATIONS[@]}"; do
    if [ -f "$location" ]; then
        DMD_BINARY="$location"
        compiler_size=$(stat -c%s "$location" 2>/dev/null || stat -f%z "$location" 2>/dev/null || echo "0")
        echo "Found DMD binary at: $location (size: $compiler_size bytes)"
        break
    fi
done

if [ "$compiler_size" -eq 0 ]; then
    echo "No DMD binary found in standard locations"
fi

echo "  \"compiler_size_bytes\": $compiler_size," >> "$RESULTS_DIR/results.json"

# Test 4: Stress Tests
if [ -f "$SCRIPT_DIR/run-stress-tests.sh" ]; then
    echo "Running stress tests..."
    source "$SCRIPT_DIR/run-stress-tests.sh"
else
    echo "Skipping stress tests - script not found"
    echo "  \"stress_tests\": {" >> "$RESULTS_DIR/results.json"
    echo "    \"template_stress_compile_time\": 0.000000000," >> "$RESULTS_DIR/results.json"
    echo "    \"ctfe_stress_compile_time\": 0.000000000" >> "$RESULTS_DIR/results.json"
    echo "  }," >> "$RESULTS_DIR/results.json"
fi

# Close JSON properly
# Remove last comma and close
sed -i '$ s/,$//' "$RESULTS_DIR/results.json"
echo "}" >> "$RESULTS_DIR/results.json"

# Validate JSON
if command -v python3 &> /dev/null; then
    if python3 -c "import json; json.load(open('$RESULTS_DIR/results.json'))" 2>/dev/null; then
        echo "✓ Generated valid JSON results"
    else
        echo "✗ Warning: Generated JSON may be invalid"
    fi
fi

# Generate summary
if [ -f "$SCRIPT_DIR/generate-summary.py" ]; then
    echo "Generating summary..."
    python3 "$SCRIPT_DIR/generate-summary.py"
else
    echo "Summary generator not found - skipping"
fi

# Run comparison if this is a PR
if [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
    if [ -f "$SCRIPT_DIR/compare-with-baseline.py" ]; then
        echo "Running PR comparison..."
        python3 "$SCRIPT_DIR/compare-with-baseline.py"
    else
        echo "PR comparison script not found - skipping"
    fi
fi

echo ""
echo "Performance tests completed!"
echo "Results saved to: $RESULTS_DIR/results.json"
echo ""
echo "Summary:"
echo "- Test suite duration: ${test_duration}s"
echo "- Compiler size: ${compiler_size} bytes"
if [ -n "$DMD_BINARY" ]; then
    echo "- DMD binary: $DMD_BINARY"
fi
echo ""

# Show results file location and brief contents
if [ -f "$RESULTS_DIR/results.json" ]; then
    echo "Results preview:"
    head -10 "$RESULTS_DIR/results.json"
    if [ $(wc -l < "$RESULTS_DIR/results.json") -gt 10 ]; then
        echo "... (truncated, see full file at $RESULTS_DIR/results.json)"
    fi
fi