#!/bin/bash
# DMD Performance Test Script
# Usage: ./dmd-performance-test.sh [baseline|pr|standalone]

set -euo pipefail

TEST_TYPE="${1:-pr}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="$PROJECT_ROOT/perf-results"

mkdir -p "$RESULTS_DIR"

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Format duration helper with better precision
format_duration() {
    local duration="$1"
    if [[ "$duration" == "999.000000000" ]] || [[ "$duration" == "999.000" ]]; then
        echo "FAILED"
    elif [[ "$duration" == "skipped" ]]; then
        echo "SKIPPED"
    else
        printf "%.6f" "$duration" 2>/dev/null || echo "ERROR"
    fi
}

# Enhanced DMD finder with validation
find_dmd() {
    local dmd_paths=(
        "generated/linux/release/64/dmd"
        "generated/linux/debug/64/dmd"
        "generated/osx/release/64/dmd"
        "generated/osx/debug/64/dmd"
        "generated/windows/release/64/dmd.exe"
        "src/dmd"
        "dmd"
    )

    for path in "${dmd_paths[@]}"; do
        local full_path="$PROJECT_ROOT/$path"
        if [ -f "$full_path" ] && [ -x "$full_path" ]; then
            # Test if DMD actually works
            if "$full_path" --version >/dev/null 2>&1; then
                echo "$full_path"
                return 0
            else
                log_warning "Found DMD at $full_path but it's not functional"
            fi
        fi
    done

    echo ""
    return 1
}

# JSON helper functions
init_json() {
    cat > "$RESULTS_DIR/results.json" << EOF
{
  "timestamp": "$(date -Iseconds)",
  "test_type": "$TEST_TYPE",
  "host_info": {
    "hostname": "$(hostname)",
    "os": "$(uname -s)",
    "arch": "$(uname -m)",
    "kernel": "$(uname -r)"
  },
EOF

    if git rev-parse --git-dir > /dev/null 2>&1; then
        cat >> "$RESULTS_DIR/results.json" << EOF
  "git_info": {
    "commit": "$(git rev-parse HEAD)",
    "short_commit": "$(git rev-parse --short HEAD)",
    "branch": "$(git branch --show-current 2>/dev/null || echo 'detached')",
    "dirty": $(git diff --quiet && echo 'false' || echo 'true')
  },
EOF
    fi

    echo '  "tests": {}' >> "$RESULTS_DIR/results.json"
    echo '}' >> "$RESULTS_DIR/results.json"
}

add_test_result() {
    local key="$1"
    local value="$2"
    local description="${3:-}"
    
    local tmpfile=$(mktemp)
    jq --arg key "$key" --arg value "$value" --arg desc "$description" \
       '.tests[$key] = {"duration": $value, "description": $desc}' \
       "$RESULTS_DIR/results.json" > "$tmpfile"
    mv "$tmpfile" "$RESULTS_DIR/results.json"
}

# Enhanced timing function with timeout and error handling
run_timed_test() {
    local test_name="$1"
    local test_description="$2"
    local command="$3"
    local timeout_seconds="${4:-300}"
    local work_dir="${5:-$PROJECT_ROOT}"
    
    log_info "Running: $test_description"
    
    # Create isolated test environment
    local temp_script=$(mktemp)
    local error_log=$(mktemp)
    local output_log=$(mktemp)
    
    cat > "$temp_script" << SCRIPT_EOF
#!/bin/bash
set -euo pipefail
cd "$work_dir"
$command
SCRIPT_EOF
    chmod +x "$temp_script"
    
    local start_time=$(date +%s.%N)
    local exit_code=0
    
    if timeout "$timeout_seconds" "$temp_script" >"$output_log" 2>"$error_log"; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc -l)
        add_test_result "$test_name" "$duration" "$test_description"
        log_success "$test_description completed in $(format_duration "$duration")"
    else
        exit_code=$?
        add_test_result "$test_name" "999.000000000" "$test_description"
        if [ $exit_code -eq 124 ]; then
            log_error "$test_description timed out after ${timeout_seconds}s"
        else
            log_error "$test_description failed (exit code: $exit_code)"
            log_warning "Error output:"
            head -10 "$error_log" | sed 's/^/  /'
        fi
    fi
    
    rm -f "$temp_script" "$error_log" "$output_log"
    return $exit_code
}

echo "=== DMD Performance Test Suite ($TEST_TYPE) ==="
cd "$PROJECT_ROOT"

# Build DMD if not already present
DMD_BINARY="generated/linux/release/64/dmd"
if [ ! -f "$DMD_BINARY" ]; then
    log_warning "DMD binary not found at $DMD_BINARY, attempting to build..."
    if make -f posix.mak -j auto; then
        log_success "DMD build completed"
    else
        log_error "Build failed. Check build logs for errors."
        find generated/ -type f 2>/dev/null || true
        exit 1
    fi
fi

if [ ! -f "$DMD_BINARY" ]; then
    log_error "DMD binary still not found at $DMD_BINARY after build attempt."
    log_info "Contents of generated/:"
    find generated/ -type f 2>/dev/null || true
    exit 1
fi

log_success "DMD binary found at $DMD_BINARY"

# Test DMD basic functionality
if ! "$DMD_BINARY" --version >/dev/null 2>&1; then
    log_error "DMD binary is not working"
    exit 1
fi

log_info "DMD binary is working."

# Initialize results JSON
init_json

# Find and validate DMD binary
DMD_BINARY=$(find_dmd)
if [ -z "$DMD_BINARY" ]; then
    log_error "DMD binary not found in any standard location!"
    log_info "Searching for DMD binaries..."
    find . -name "*dmd*" -type f -executable 2>/dev/null | head -5 || true
    exit 1
fi

log_success "Using DMD: $DMD_BINARY"
log_info "DMD Version: $("$DMD_BINARY" --version | head -1)"

# Setup environment for library detection
setup_environment() {
    export DMD_PATH="$DMD_BINARY"
    
    # Find library paths
    local druntime_lib=""
    local phobos_lib=""
    
    # Look for druntime
    if [ -d "generated/linux/release/64" ]; then
        druntime_lib="$(pwd)/generated/linux/release/64"
    elif [ -d "druntime" ]; then
        local druntime_search=$(find druntime -name "*.a" -o -name "*.so" 2>/dev/null | head -1)
        if [ -n "$druntime_search" ]; then
            druntime_lib="$(dirname "$druntime_search")"
        fi
    fi
    
    # Look for phobos
    if [ -d "phobos/generated/linux/release/64" ]; then
        phobos_lib="$(pwd)/phobos/generated/linux/release/64"
    elif [ -d "phobos" ]; then
        local phobos_search=$(find phobos -name "*.a" -o -name "*.so" 2>/dev/null | head -1)
        if [ -n "$phobos_search" ]; then
            phobos_lib="$(dirname "$phobos_search")"
        fi
    fi
    
    export LIBRARY_PATH="$druntime_lib:$phobos_lib"
    export LD_LIBRARY_PATH="$druntime_lib:$phobos_lib"
    
    log_info "Environment configured:"
    log_info "  DMD_PATH: $DMD_PATH"
    log_info "  DRUNTIME_LIB: $druntime_lib"
    log_info "  PHOBOS_LIB: $phobos_lib"
}

setup_environment

# Test 1: Basic Compilation Speed
run_timed_test "simple_compile" "Simple compilation test" \
    "echo 'void main() { int x = 42; }' > test_simple.d && \
     '$DMD_BINARY' -c test_simple.d && rm -f test_simple.d test_simple.o" \
    60

# Test 2: Template Instantiation Performance
create_template_test() {
    cat > template_heavy.d << 'EOF'
template Factorial(int n) {
    static if (n <= 1)
        enum Factorial = 1;
    else
        enum Factorial = n * Factorial!(n-1);
}

template Fibonacci(int n) {
    static if (n <= 1)
        enum Fibonacci = n;
    else
        enum Fibonacci = Fibonacci!(n-1) + Fibonacci!(n-2);
}

template IsPrime(int n) {
    static if (n < 2)
        enum IsPrime = false;
    else static if (n == 2)
        enum IsPrime = true;
    else static if (n % 2 == 0)
        enum IsPrime = false;
    else {
        template CheckDivisor(int d) {
            static if (d * d > n)
                enum CheckDivisor = true;
            else static if (n % d == 0)
                enum CheckDivisor = false;
            else
                enum CheckDivisor = CheckDivisor!(d + 2);
        }
    
    int computeSum() {
        int sum = 0;
        foreach (val; data) {
            sum += val;
        }
        return sum;
    }
    
    string concatenateStrings() {
        string result = "";
        foreach (str; strings) {
            result ~= str ~ "_";
        }
        return result;
    }
    
    int complexComputation() {
        int result = 0;
        foreach (i; 0 .. 1000) {
            foreach (j; 0 .. 100) {
                if (i % 10 == j % 10) {
                    result += data[i] + cast(int)strings[j].length;
                }
            }
        }
        return result;
    }
}

void main() {
    auto test = new OptimizationTest();
    int sum = test.computeSum();
    string concat = test.concatenateStrings();
    int complex = test.complexComputation();
}
EOF

# Test different optimization levels
run_timed_test "compile_debug" "Debug compilation (-debug)" \
    "'$DMD_BINARY' -debug -c optimization_test.d -of=opt_debug.o" \
    60 "$temp_dir"

run_timed_test "compile_release" "Release compilation (-release -O)" \
    "'$DMD_BINARY' -release -O -c optimization_test.d -of=opt_release.o" \
    60 "$temp_dir"

run_timed_test "compile_inline" "Inline compilation (-release -O -inline)" \
    "'$DMD_BINARY' -release -O -inline -c optimization_test.d -of=opt_inline.o" \
    90 "$temp_dir"

cd "$PROJECT_ROOT"
rm -rf "$temp_dir"

# Test 11: Memory Usage Test
temp_dir=$(mktemp -d)
cd "$temp_dir"
cat > memory_test.d << 'EOF'
class MemoryHeavy {
    int[] data;
    string[] strings;
    MemoryHeavy[] children;
    
    this(int size, int depth = 0) {
        data = new int[size];
        strings = new string[size];
        
        foreach (i; 0 .. size) {
            data[i] = i;
            strings[i] = "string_" ~ cast(char)('0' + (i % 10)) ~ "_" ~ cast(char)('0' + (depth % 10));
        }
        
        if (depth < 3) {
            foreach (i; 0 .. (size / 10)) {
                children ~= new MemoryHeavy(size / 2, depth + 1);
            }
        }
    }
    
    int computeTotal() {
        int total = 0;
        foreach (val; data) {
            total += val;
        }
        foreach (child; children) {
            total += child.computeTotal();
        }
        return total;
    }
}

void main() {
    MemoryHeavy[] objects;
    foreach (i; 0 .. 50) {
        objects ~= new MemoryHeavy(100, 0);
    }
    
    int grandTotal = 0;
    foreach (obj; objects) {
        grandTotal += obj.computeTotal();
    }
}
EOF

run_timed_test "memory_heavy_compile" "Memory-heavy code compilation" \
    "'$DMD_BINARY' -c memory_test.d" \
    120 "$temp_dir"

cd "$PROJECT_ROOT"
rm -rf "$temp_dir"

# Test 12: Error Recovery Performance
temp_dir=$(mktemp -d)
cd "$temp_dir"
cat > error_recovery.d << 'EOF'
// Test with intentional syntax errors to test error recovery
module error_recovery;

void main() {
    int x = 5;  // Missing semicolon will be added by next line
    string y = "test"  // Missing semicolon
    
    if (x > 0 {  // Missing closing parenthesis
        y = "positive";
    }
    
    foreach (i; 0..x {  // Missing closing parenthesis
        // Missing closing brace intentionally
        int z = i * 2
    
    class MissingBrace {
        int value;
        void method() {
            // Missing closing brace
    
    // Multiple syntax errors
    int[] array = [1, 2, 3  // Missing closing bracket
    string incomplete = "string without closing quote
EOF

# Time how quickly DMD can process and report errors
run_timed_test "error_recovery" "Error recovery and reporting" \
    "'$DMD_BINARY' -c error_recovery.d 2>/dev/null || true" \
    30 "$temp_dir"

cd "$PROJECT_ROOT"
rm -rf "$temp_dir"

# Test 13: Import Resolution Performance
create_import_test() {
    mkdir -p import_test/{a,b,c,d,e}
    
    # Create deep import chains
    for letter in a b c d e; do
        for i in {1..10}; do
            cat > "import_test/$letter/module$i.d" << EOF
module $letter.module$i;

struct ${letter^}Struct$i {
    int value$i = $i;
    string name$i = "${letter}_module$i";
}

int ${letter}Function$i() {
    auto s = ${letter^}Struct$i();
    return s.value$i * $i;
}
EOF
        done
    done
    
    # Create main module that imports everything
    cat > import_test/main.d << 'EOF'
module main;

// Import all modules
EOF
    
    for letter in a b c d e; do
        for i in {1..10}; do
            echo "import $letter.module$i;" >> import_test/main.d
        done
    done
    
    cat >> import_test/main.d << 'EOF'

void main() {
    int total = 0;
EOF
    
    for letter in a b c d e; do
        for i in {1..10}; do
            echo "    total += ${letter}Function$i();" >> import_test/main.d
        done
    done
    
    echo '}' >> import_test/main.d
}

temp_dir=$(mktemp -d)
cd "$temp_dir"
create_import_test
run_timed_test "import_resolution" "Import resolution performance (50 modules)" \
    "'$DMD_BINARY' -c import_test/main.d import_test/*/*.d" \
    300 "$temp_dir"
cd "$PROJECT_ROOT"
rm -rf "$temp_dir"

# Test 14: Full Linking Test (if libraries available)
setup_linking_test() {
    cat > linking_test.d << 'EOF'
void main() {
    int x = 42;
    int y = x * 2;
    int z = y + x;
}
EOF
}

# Find library paths for linking
DRUNTIME_LIB=""
PHOBOS_LIB=""

if [ -d "generated/linux/release/64" ]; then
    DRUNTIME_LIB="$(pwd)/generated/linux/release/64"
fi

if [ -d "phobos/generated/linux/release/64" ]; then
    PHOBOS_LIB="$(pwd)/phobos/generated/linux/release/64"
elif [ -d "phobos" ]; then
    PHOBOS_SEARCH=$(find phobos -name "*.a" -o -name "*.so" 2>/dev/null | head -1)
    if [ -n "$PHOBOS_SEARCH" ]; then
        PHOBOS_LIB="$(dirname "$PHOBOS_SEARCH")"
    fi
fi

temp_dir=$(mktemp -d)
cd "$temp_dir"
setup_linking_test

if [ -n "$PHOBOS_LIB" ] && [ -f "$PHOBOS_LIB/libphobos2.a" ]; then
    run_timed_test "full_link" "Full linking test with Phobos" \
        "'$DMD_BINARY' linking_test.d -of=linking_test_out -L-L'$PHOBOS_LIB' && rm -f linking_test_out" \
        120 "$temp_dir"
else
    log_warning "Phobos library not found, skipping linking test"
    add_test_result "full_link" "skipped" "Phobos library not available"
fi

cd "$PROJECT_ROOT"
rm -rf "$temp_dir"

# Record DMD binary size and metadata
if [ -f "$DMD_BINARY" ]; then
    dmd_size=$(stat -c%s "$DMD_BINARY" 2>/dev/null || stat -f%z "$DMD_BINARY" 2>/dev/null || echo "0")
    
    # Add binary info to JSON
    local tmpfile=$(mktemp)
    jq --arg size "$dmd_size" --arg path "$DMD_BINARY" \
       '.binary_info = {"size_bytes": ($size | tonumber), "path": $path}' \
       "$RESULTS_DIR/results.json" > "$tmpfile"
    mv "$tmpfile" "$RESULTS_DIR/results.json"
    
    log_success "DMD binary size: $(echo "scale=1; $dmd_size / 1024 / 1024" | bc -l)MB"
else
    log_warning "Could not determine DMD binary size"
fi

# Finalize results with completion timestamp
tmpfile=$(mktemp)
jq '.completed_at = now | .total_tests = (.tests | length)' \
   "$RESULTS_DIR/results.json" > "$tmpfile"
mv "$tmpfile" "$RESULTS_DIR/results.json"

log_success "Performance test completed!"
log_info "Results saved to: $RESULTS_DIR/results.json"

# Display comprehensive summary
echo ""
echo "=== Performance Test Summary ==="
if command -v python3 >/dev/null 2>&1; then
    python3 << 'EOF'
import json
import sys
from datetime import datetime

try:
    with open("perf-results/results.json") as f:
        data = json.load(f)
except Exception as e:
    print(f"Error reading results: {e}")
    sys.exit(1)

def fmt_time(test_data):
    if isinstance(test_data, dict):
        duration = test_data.get('duration', '0')
    else:
        duration = test_data
    
    if str(duration) == '999.000000000':
        return 'FAILED'
    elif str(duration) == 'skipped':
        return 'SKIPPED'
    else:
        try:
            return f'{float(duration):.3f}s'
        except:
            return 'ERROR'

def get_description(test_data, fallback):
    if isinstance(test_data, dict):
        return test_data.get('description', fallback)
    return fallback

print("=" * 60)
print(f"DMD PERFORMANCE TEST RESULTS")
print("=" * 60)
print(f"Test Type: {data.get('test_type', 'unknown')}")
print(f"Timestamp: {data.get('timestamp', 'unknown')}")

if 'host_info' in data:
    host = data['host_info']
    print(f"Host: {host.get('hostname', 'unknown')} ({host.get('os', 'unknown')} {host.get('arch', 'unknown')})")

if 'git_info' in data:
    git = data['git_info']
    dirty_status = " (dirty)" if git.get('dirty', False) else ""
    print(f"Commit: {git.get('short_commit', 'unknown')} ({git.get('branch', 'unknown')}){dirty_status}")

print()

# Group tests by category
test_categories = {
    "Basic Compilation": ["simple_compile", "compile_debug", "compile_release", "compile_inline"],
    "Template & CTFE": ["template_stress", "ctfe_stress"],
    "Large Projects": ["large_file_compile", "multifile_compile", "incremental_compile", "import_resolution"],
    "Full System": ["test_suite", "self_compile", "real_project_compile"],
    "Advanced": ["memory_heavy_compile", "full_link", "error_recovery"]
}

tests = data.get('tests', {})

for category, test_names in test_categories.items():
    category_tests = {name: tests[name] for name in test_names if name in tests}
    if category_tests:
        print(f"{category}:")
        for test_name, test_data in category_tests.items():
            duration = fmt_time(test_data)
            description = get_description(test_data, test_name.replace('_', ' ').title())
            print(f"  {description:<45} {duration:>12}")
        print()

# Show binary info
if 'binary_info' in data and data['binary_info']['size_bytes'] > 0:
    size_mb = data['binary_info']['size_bytes'] / (1024 * 1024)
    print(f"DMD Binary:")
    print(f"  Size: {size_mb:.1f}MB")
    print(f"  Path: {data['binary_info']['path']}")
    print()

# Summary statistics
total_tests = len(tests)
failed_tests = sum(1 for t in tests.values() if 
                  (isinstance(t, dict) and str(t.get('duration')) == '999.000000000') or
                  (isinstance(t, str) and str(t) == '999.000000000'))
skipped_tests = sum(1 for t in tests.values() if 
                   (isinstance(t, dict) and str(t.get('duration')) == 'skipped') or
                   (isinstance(t, str) and str(t) == 'skipped'))
passed_tests = total_tests - failed_tests - skipped_tests

print("=" * 60)
print(f"SUMMARY: {total_tests} total | {passed_tests} passed | {failed_tests} failed | {skipped_tests} skipped")

if failed_tests > 0:
    print()
    print("FAILED TESTS:")
    for name, data in tests.items():
        duration = data.get('duration') if isinstance(data, dict) else data
        if str(duration) == '999.000000000':
            description = get_description(data, name.replace('_', ' ').title())
            print(f"  ❌ {description}")

if skipped_tests > 0:
    print()
    print("SKIPPED TESTS:")
    for name, data in tests.items():
        duration = data.get('duration') if isinstance(data, dict) else data
        if str(duration) == 'skipped':
            description = get_description(data, name.replace('_', ' ').title())
            print(f"  ⏭️  {description}")

# Performance analysis
compilation_times = []
for name, data in tests.items():
    duration = data.get('duration') if isinstance(data, dict) else data
    try:
        time_val = float(duration)
        if time_val < 999.0:  # Valid timing
            compilation_times.append(time_val)
    except:
        pass

if compilation_times:
    avg_time = sum(compilation_times) / len(compilation_times)
    max_time = max(compilation_times)
    min_time = min(compilation_times)
    print()
    print("PERFORMANCE METRICS:")
    print(f"  Average compilation time: {avg_time:.3f}s")
    print(f"  Fastest test: {min_time:.3f}s")
    print(f"  Slowest test: {max_time:.3f}s")

print("=" * 60)
EOF
else
    # Fallback to basic jq summary if python3 not available
    log_info "Python3 not available, showing basic summary:"
    if command -v jq >/dev/null 2>&1; then
        echo "Test Type: $(jq -r '.test_type' "$RESULTS_DIR/results.json")"
        echo "Timestamp: $(jq -r '.timestamp' "$RESULTS_DIR/results.json")"
        
        if jq -e '.git_info' "$RESULTS_DIR/results.json" >/dev/null; then
            echo "Git Info: $(jq -r '.git_info.short_commit + " (" + .git_info.branch + ")"' "$RESULTS_DIR/results.json")"
        fi
        
        echo ""
        echo "Test results:"
        jq -r '.tests | to_entries[] | "  " + (.key | gsub("_"; " ") | ascii_upcase) + ": " + (.value.duration // .value)' "$RESULTS_DIR/results.json"
        
        if jq -e '.binary_info' "$RESULTS_DIR/results.json" >/dev/null; then
            echo ""
            echo "Binary size: $(jq -r '(.binary_info.size_bytes / 1024 / 1024 * 100 | floor) / 100' "$RESULTS_DIR/results.json")MB"
        fi
        
        echo ""
        total_tests=$(jq '.tests | length' "$RESULTS_DIR/results.json")
        failed_tests=$(jq '[.tests[] | select((.duration // .) == "999.000000000")] | length' "$RESULTS_DIR/results.json")
        skipped_tests=$(jq '[.tests[] | select((.duration // .) == "skipped")] | length' "$RESULTS_DIR/results.json")
        passed_tests=$((total_tests - failed_tests - skipped_tests))
        
        echo "Summary: $total_tests total | $passed_tests passed | $failed_tests failed | $skipped_tests skipped"
    else
        log_warning "Neither python3 nor jq available for summary generation"
        echo "Raw results:"
        cat "$RESULTS_DIR/results.json"
    fi
fi

# Check for critical performance regressions if this is a PR test
if [ "$TEST_TYPE" = "pr" ] && command -v python3 >/dev/null 2>&1; then
    echo ""
    echo "=== Performance Analysis ==="
    
    # Look for baseline results
    if [ -f "$RESULTS_DIR/../baseline.json" ] || [ -f "/tmp/perf-results/baseline.json" ]; then
        baseline_file=""
        if [ -f "$RESULTS_DIR/../baseline.json" ]; then
            baseline_file="$RESULTS_DIR/../baseline.json"
        else
            baseline_file="/tmp/perf-results/baseline.json"
        fi
        
        python3 << EOF
import json

try:
    with open("$baseline_file") as f:
        baseline = json.load(f)
    with open("$RESULTS_DIR/results.json") as f:
        pr = json.load(f)
except Exception as e:
    print(f"Could not load comparison data: {e}")
    exit()

def safe_float(val):
    try:
        if isinstance(val, dict):
            val = val.get('duration', '0')
        return float(val) if str(val) not in ['999.000000000', 'skipped'] else None
    except:
        return None

print("Performance Comparison vs Baseline:")
print("-" * 50)

baseline_tests = baseline.get('tests', {})
pr_tests = pr.get('tests', {})

regressions = []
improvements = []

for test_name in pr_tests:
    if test_name in baseline_tests:
        baseline_time = safe_float(baseline_tests[test_name])
        pr_time = safe_float(pr_tests[test_name])
        
        if baseline_time and pr_time:
            change_pct = ((pr_time - baseline_time) / baseline_time) * 100
            
            if abs(change_pct) >= 5:  # Significant change threshold
                test_desc = test_name.replace('_', ' ').title()
                if change_pct > 0:
                    regressions.append(f"  🔻 {test_desc}: {change_pct:.1f}% slower ({baseline_time:.3f}s → {pr_time:.3f}s)")
                else:
                    improvements.append(f"  🚀 {test_desc}: {abs(change_pct):.1f}% faster ({baseline_time:.3f}s → {pr_time:.3f}s)")

if improvements:
    print("PERFORMANCE IMPROVEMENTS:")
    for improvement in improvements:
        print(improvement)
    print()

if regressions:
    print("PERFORMANCE REGRESSIONS:")
    for regression in regressions:
        print(regression)
    print()
    
    # Check for critical regressions (>25% slower)
    critical = [r for r in regressions if "%" in r and float(r.split("%")[0].split()[-1]) > 25]
    if critical:
        print("⚠️  CRITICAL REGRESSIONS DETECTED (>25% slower)")
        exit(1)
else:
    if not improvements:
        print("No significant performance changes detected.")
    
print("-" * 50)
EOF
    else
        log_info "No baseline results found for comparison"
    fi
fi

echo ""
log_success "All performance tests completed!"
log_info "Full results available in: $RESULTS_DIR/results.json"    enum IsPrime = CheckDivisor!3;
    }
}

template Power(int base, int exp) {
    static if (exp == 0)
        enum Power = 1;
    else
        enum Power = base * Power!(base, exp-1);
}

void main() {
    // Force heavy template instantiation
    enum f1 = Factorial!5;
    enum f2 = Factorial!10;
    enum f3 = Factorial!12;
    
    enum fib1 = Fibonacci!15;
    enum fib2 = Fibonacci!18;
    
    enum p1 = IsPrime!97;
    enum p2 = IsPrime!101;
    enum p3 = IsPrime!103;
    
    enum pow1 = Power!(2, 10);
    enum pow2 = Power!(3, 8);
    enum pow3 = Power!(5, 6);
}
EOF
}

temp_dir=$(mktemp -d)
cd "$temp_dir"
create_template_test
run_timed_test "template_stress" "Template instantiation stress test" \
    "'$DMD_BINARY' -c template_heavy.d" \
    120 "$temp_dir"
cd "$PROJECT_ROOT"
rm -rf "$temp_dir"

# Test 3: CTFE Performance
create_ctfe_test() {
    cat > ctfe_heavy.d << 'EOF'
string repeat(string s, int n) {
    string result = "";
    for (int i = 0; i < n; i++) {
        result ~= s;
    }
    return result;
}

int[] generateSequence(int n) {
    int[] result;
    for (int i = 0; i < n; i++) {
        result ~= i * i + i;
    }
    return result;
}

string generateSwitch(int n) {
    string result = "switch(x) {\n";
    for (int i = 0; i < n; i++) {
        result ~= "case " ~ intToString(i) ~ ": return " ~ intToString(i * 2) ~ ";\n";
    }
    result ~= "default: return 0;\n}";
    return result;
}

string intToString(int value) {
    if (value == 0) return "0";
    
    string result = "";
    int temp = value < 0 ? -value : value;
    
    while (temp > 0) {
        result = cast(char)('0' + (temp % 10)) ~ result;
        temp /= 10;
    }
    
    return value < 0 ? "-" ~ result : result;
}

int fibonacci(int n) {
    if (n <= 1) return n;
    return fibonacci(n-1) + fibonacci(n-2);
}

void main() {
    // Force CTFE execution
    enum repeated = repeat("test", 100);
    enum sequence = generateSequence(200);
    enum switchCode = generateSwitch(50);
    enum fib10 = fibonacci(10);
    enum fib12 = fibonacci(12);
    
    // Use the computed values
    int useRepeated = repeated.length;
    int useSequence = sequence.length;
    int useSwitchCode = switchCode.length;
    int useFib = fib10 + fib12;
}
EOF
}

temp_dir=$(mktemp -d)
cd "$temp_dir"
create_ctfe_test
run_timed_test "ctfe_stress" "CTFE heavy computation test" \
    "'$DMD_BINARY' -c ctfe_heavy.d" \
    180 "$temp_dir"
cd "$PROJECT_ROOT"
rm -rf "$temp_dir"

# Test 4: Large File Compilation
create_large_file() {
    cat > large_file.d << 'EOF'
module large_file;

EOF

    # Generate many functions and classes
    for i in {1..300}; do
        cat >> large_file.d << EOF
struct DataStruct$i {
    int value$i;
    string name$i;
    
    this(int v, string n) {
        value$i = v;
        name$i = n;
    }
    
    int compute$i() {
        int result = value$i;
        for (int j = 0; j < 10; j++) {
            result = (result * 3 + j) % 1000;
        }
        return result;
    }
}

int function$i(int param) {
    auto data = DataStruct$i(param, "test$i");
    return data.compute$i();
}
EOF
    done

    cat >> large_file.d << 'EOF'
void main() {
    int total = 0;
EOF

    for i in {1..300}; do
        echo "    total += function$i($i);" >> large_file.d
    done

    echo '}' >> large_file.d
}

temp_dir=$(mktemp -d)
cd "$temp_dir"
create_large_file
run_timed_test "large_file_compile" "Large file compilation (300 functions)" \
    "'$DMD_BINARY' -c large_file.d" \
    300 "$temp_dir"
cd "$PROJECT_ROOT"
rm -rf "$temp_dir"

# Test 5: Multi-file Project Compilation
create_multifile_project() {
    mkdir -p multifile/{core,utils,parser}
    
    # Core module
    cat > multifile/core/base.d << 'EOF'
module core.base;

interface IProcessor {
    string process(string input);
}

abstract class BaseProcessor : IProcessor {
    protected string name;
    this(string n) { name = n; }
    abstract override string process(string input);
}

enum ProcessorType {
    SIMPLE,
    COMPLEX,
    ADVANCED
}
EOF

    # Utility modules
    for i in {1..5}; do
        cat > "multifile/utils/util$i.d" << EOF
module utils.util$i;
import core.base;

class Processor$i : BaseProcessor {
    private ProcessorType type;
    
    this(ProcessorType t = ProcessorType.SIMPLE) { 
        super("Processor$i"); 
        type = t;
    }
    
    override string process(string input) {
        string result = input;
        for (int j = 0; j < $i; j++) {
            result ~= "_processed$i";
        }
        return result;
    }
    
    string advancedProcess(string input) {
        string result = process(input);
        if (type == ProcessorType.ADVANCED) {
            result ~= "_advanced";
        }
        return result;
    }
}

string utilFunction$i(string data) {
    auto processor = new Processor$i(ProcessorType.COMPLEX);
    return processor.advancedProcess(data);
}
EOF
    done

    # Parser modules
    for i in {1..3}; do
        cat > "multifile/parser/parser$i.d" << EOF
module parser.parser$i;
import core.base;
import utils.util1;
import utils.util2;

class Parser$i {
    private IProcessor[] processors;
    
    this() {
        processors ~= new Processor1();
        processors ~= new Processor2();
    }
    
    string parseData$i(string input) {
        string result = utilFunction1(input);
        result = utilFunction2(result);
        
        foreach (processor; processors) {
            result = processor.process(result);
        }
        
        return result ~ "_parsed$i";
    }
}
EOF
    done

    # Main module
    cat > multifile/main.d << 'EOF'
module main;
import core.base;
import utils.util1, utils.util2, utils.util3, utils.util4, utils.util5;
import parser.parser1, parser.parser2, parser.parser3;

void main() {
    string testData = "input";
    
    // Use all utilities
    string result1 = utilFunction1(testData);
    string result2 = utilFunction2(result1);
    string result3 = utilFunction3(result2);
    string result4 = utilFunction4(result3);
    string result5 = utilFunction5(result4);
    
    // Use all parsers
    auto parser1 = new Parser1();
    auto parser2 = new Parser2();
    auto parser3 = new Parser3();
    
    string finalResult = parser1.parseData1(
        parser2.parseData2(
            parser3.parseData3(result5)
        )
    );
}
EOF
}

temp_dir=$(mktemp -d)
cd "$temp_dir"
create_multifile_project
run_timed_test "multifile_compile" "Multi-file project compilation" \
    "'$DMD_BINARY' -c multifile/main.d multifile/core/*.d multifile/utils/*.d multifile/parser/*.d" \
    240 "$temp_dir"
cd "$PROJECT_ROOT"
rm -rf "$temp_dir"

# Test 6: DMD Test Suite Performance (if available)
if [ -f "posix.mak" ]; then
    log_info "Running DMD test suite..."
    run_timed_test "test_suite" "DMD test suite execution" \
        "timeout 1200 make -f posix.mak test MODEL=64 > /dev/null 2>&1 || echo 'Test suite completed/timed out'" \
        1800
elif [ -f "Makefile" ]; then
    run_timed_test "test_suite" "DMD test suite execution" \
        "timeout 1200 make test > /dev/null 2>&1 || echo 'Test suite completed/timed out'" \
        1800
else
    log_warning "No makefile found, skipping test suite"
    add_test_result "test_suite" "skipped" "Test suite not available"
fi

# Test 7: Real D Project Compilation
create_real_d_project() {
    mkdir -p src/{core,util,parser,backend}

    # Main module - realistic D project
    cat > src/main.d << 'EOF'
module main;

struct Token {
    string type;
    string value;
    size_t line;
    size_t column;
}

class Lexer {
    private string input;
    private size_t position;
    private size_t line;
    private size_t column;
    
    this(string inp) {
        input = inp;
        position = 0;
        line = 1;
        column = 1;
    }
    
    Token[] tokenize() {
        Token[] tokens;
        while (position < input.length) {
            char c = input[position];
            if (c == ' ' || c == '\t') {
                advance();
            } else if (c == '\n') {
                advance();
                line++;
                column = 1;
            } else if (c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
                tokens ~= readIdentifier();
            } else if (c >= '0' && c <= '9') {
                tokens ~= readNumber();
            } else {
                tokens ~= Token("SYMBOL", [c], line, column);
                advance();
            }
        }
        return tokens;
    }
    
    private void advance() {
        position++;
        column++;
    }
    
    private Token readIdentifier() {
        size_t start = position;
        while (position < input.length) {
            char c = input[position];
            if (c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') {
                advance();
            } else {
                break;
            }
        }
        return Token("IDENTIFIER", input[start..position], line, column);
    }
    
    private Token readNumber() {
        size_t start = position;
        while (position < input.length) {
            char c = input[position];
            if (c >= '0' && c <= '9') {
                advance();
            } else {
                break;
            }
        }
        return Token("NUMBER", input[start..position], line, column);
    }
}

abstract class ASTNode {
    abstract override string toString();
    abstract void accept(Visitor visitor);
}

interface Visitor {
    void visit(Expression expr);
    void visit(Statement stmt);
    void visit(Program prog);
}

class Expression : ASTNode {
    string value;
    this(string v) { value = v; }
    override string toString() { return "Expr(" ~ value ~ ")"; }
    override void accept(Visitor visitor) { visitor.visit(this); }
}

class Statement : ASTNode {
    ASTNode[] children;
    string statementType;
    
    this(string type) { statementType = type; }
    
    override string toString() { 
        return "Stmt(" ~ statementType ~ ", " ~ 
               cast(char)('0' + children.length) ~ " children)"; 
    }
    
    override void accept(Visitor visitor) { visitor.visit(this); }
}

class Program : ASTNode {
    Statement[] statements;
    
    override string toString() { 
        return "Program(" ~ cast(char)('0' + statements.length) ~ " statements)"; 
    }
    
    override void accept(Visitor visitor) { visitor.visit(this); }
}

class Parser {
    private Token[] tokens;
    private size_t position;
    
    this(Token[] toks) {
        tokens = toks;
        position = 0;
    }
    
    Program parse() {
        auto program = new Program();
        while (position < tokens.length) {
            auto stmt = parseStatement();
            if (stmt !is null) {
                program.statements ~= stmt;
            }
        }
        return program;
    }
    
    private Statement parseStatement() {
        if (position >= tokens.length) return null;
        
        auto stmt = new Statement("generic");
        while (position < tokens.length && tokens[position].type != "SYMBOL") {
            stmt.children ~= new Expression(tokens[position].value);
            position++;
        }
        
        if (position < tokens.length) {
            position++; // Skip symbol
        }
        
        return stmt;
    }
}

class CodeGeneratorVisitor : Visitor {
    private string[] output;
    
    void visit(Expression expr) {
        output ~= "// Expression: " ~ expr.value;
    }
    
    void visit(Statement stmt) {
        output ~= "// Statement: " ~ stmt.statementType;
        foreach (child; stmt.children) {
            child.accept(this);
        }
    }
    
    void visit(Program prog) {
        output ~= "// Program start";
        foreach (stmt; prog.statements) {
            stmt.accept(this);
        }
        output ~= "// Program end";
    }
    
    string getCode() {
        string result = "";
        foreach (line; output) {
            result ~= line ~ "\n";
        }
        return result;
    }
}

void main(string[] args) {
    string testInput = "hello world test input 123 456 more data here";
    
    auto lexer = new Lexer(testInput);
    auto tokens = lexer.tokenize();
    
    auto parser = new Parser(tokens);
    auto ast = parser.parse();
    
    auto codegen = new CodeGeneratorVisitor();
    ast.accept(codegen);
    string generatedCode = codegen.getCode();
}
EOF
}

temp_dir=$(mktemp -d)
cd "$temp_dir"
create_real_d_project
run_timed_test "real_project_compile" "Real D project compilation" \
    "'$DMD_BINARY' -c src/main.d" \
    180 "$temp_dir"
cd "$PROJECT_ROOT"
rm -rf "$temp_dir"

# Test 8: DMD Self-Compilation (if source available)
if [ -f "src/dmd/mars.d" ] || [ -f "mars.d" ] || [ -f "src/mars.d" ]; then
    log_info "Testing DMD self-compilation..."
    
    # Clean previous build to ensure fresh compilation
    make -f posix.mak clean >/dev/null 2>&1 || true
    
    run_timed_test "self_compile" "DMD self-compilation" \
        "make -f posix.mak -j1 HOST_DMD='$DMD_BINARY' MODEL=64 >/dev/null 2>&1" \
        900
else
    log_warning "DMD source not found, skipping self-compilation test"
    add_test_result "self_compile" "skipped" "DMD source not available"
fi

# Test 9: Incremental Compilation Test
create_incremental_test() {
    mkdir -p incremental
    
    # Create base module
    cat > incremental/base.d << 'EOF'
module base;

interface IBase {
    int getValue();
    string getName();
}

abstract class AbstractBase : IBase {
    protected int _value;
    protected string _name;
    
    this(int v, string n) { 
        _value = v; 
        _name = n; 
    }
    
    int getValue() { return _value; }
    string getName() { return _name; }
}

class BaseImpl : AbstractBase {
    this(int v) { super(v, "BaseImpl"); }
}
EOF

    # Create modules that depend on base
    for i in {1..15}; do
        cat > "incremental/derived$i.d" << EOF
module derived$i;
import base;

class Derived$i : BaseImpl {
    private int multiplier$i;
    
    this(int mult = $i) { 
        super($i * 10); 
        multiplier$i = mult;
    }
    
    override int getValue() {
        return super.getValue() + multiplier$i;
    }
    
    override string getName() {
        return super.getName() ~ "_Derived$i";
    }
}

class Manager$i {
    private Derived$i[] instances;
    
    void addInstance(Derived$i inst) {
        instances ~= inst;
    }
    
    int getTotalValue() {
        int total = 0;
        foreach (inst; instances) {
            total += inst.getValue();
        }
        return total;
    }
}

int processDerived$i() {
    auto manager = new Manager$i();
    foreach (j; 0 .. 5) {
        manager.addInstance(new Derived$i(j + 1));
    }
    return manager.getTotalValue();
}
EOF
    done

    # Main that imports everything
    cat > incremental/main.d << 'EOF'
module main;
import base;
EOF

    for i in {1..15}; do
        echo "import derived$i;" >> incremental/main.d
    done

    cat >> incremental/main.d << 'EOF'

void main() {
    auto base = new BaseImpl(100);
    int total = base.getValue();
EOF

    for i in {1..15}; do
        echo "    total += processDerived$i();" >> incremental/main.d
    done

    echo '}' >> incremental/main.d
}

temp_dir=$(mktemp -d)
cd "$temp_dir"
create_incremental_test
run_timed_test "incremental_compile" "Incremental compilation test (15 modules)" \
    "'$DMD_BINARY' -c incremental/*.d" \
    180 "$temp_dir"
cd "$PROJECT_ROOT"
rm -rf "$temp_dir"

# Test 10: Optimization Level Performance
temp_dir=$(mktemp -d)
cd "$temp_dir"
cat > optimization_test.d << 'EOF'
class OptimizationTest {
    private int[1000] data;
    private string[100] strings;
    
    this() {
        foreach (i; 0 .. 1000) {
            data[i] = i * i;
        }
        foreach (i; 0 .. 100) {
            strings[i] = "string_" ~ cast(char)('0' + (i % 10));
        }
    }
