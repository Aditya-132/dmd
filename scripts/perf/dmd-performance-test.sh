#!/bin/bash
# DMD Performance Test Script
# Usage: ./dmd-performance-test.sh [baseline|pr]

set -e

TEST_TYPE="${1:-pr}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="$PROJECT_ROOT/perf-results"

mkdir -p "$RESULTS_DIR"

# Format duration helper
format_duration() {
    local duration="$1"
    printf "%.9f" "$duration" | sed 's/^\./0./'
}

# Find DMD binary
find_dmd() {
    local dmd_paths=(
        "generated/linux/release/64/dmd"
        "generated/linux/debug/64/dmd"
        "generated/osx/release/64/dmd"
        "src/dmd"
        "dmd"
    )
    
    for path in "${dmd_paths[@]}"; do
        if [ -f "$PROJECT_ROOT/$path" ]; then
            echo "$PROJECT_ROOT/$path"
            return 0
        fi
    done
    
    echo ""
    return 1
}

echo "=== DMD Performance Test ($TEST_TYPE) ==="
cd "$PROJECT_ROOT"

# Initialize results
{
    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"test_type\": \"$TEST_TYPE\","
    if git rev-parse --git-dir > /dev/null 2>&1; then
        echo "  \"commit\": \"$(git rev-parse HEAD)\","
        echo "  \"branch\": \"$(git branch --show-current 2>/dev/null || echo 'unknown')\","
    fi
} > "$RESULTS_DIR/results.json"

# Find DMD binary
DMD_BINARY=$(find_dmd)
if [ -z "$DMD_BINARY" ]; then
    echo "❌ DMD binary not found!"
    exit 1
fi

echo "📍 Using DMD: $DMD_BINARY"

# Test 1: DMD Test Suite Performance
echo "🧪 Running DMD test suite..."
start_time=$(date +%s.%N)
timeout 1200 make test > /dev/null 2>&1 || echo "Test suite completed/timed out"
end_time=$(date +%s.%N)
test_suite_duration=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")
echo "  \"test_suite_duration\": $test_suite_duration," >> "$RESULTS_DIR/results.json"

# Test 2: Real D Project Compilation
echo "🏗️  Testing real D project compilation..."
create_real_d_project() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    # Create a realistic D project structure
    mkdir -p src/{core,util,parser,backend}
    
    # Main module - simplified to avoid import issues
    cat > src/main.d << 'EOF'
module main;

// Simple test without external imports
struct Token {
    string type;
    string value;
    size_t line;
}

class Lexer {
    Token[] tokenize(string input) {
        Token[] tokens;
        // Simple tokenization
        foreach (i, char c; input) {
            if (c != ' ' && c != '\n') {
                tokens ~= Token("CHAR", [c], i);
            }
        }
        return tokens;
    }
}

abstract class ASTNode {
    abstract override string toString();
}

class Expression : ASTNode {
    string value;
    this(string v) { value = v; }
    override string toString() { return value; }
}

class Statement : ASTNode {
    ASTNode[] children;
    override string toString() { return "Statement"; }
}

class Parser {
    ASTNode parse(Token[] tokens) {
        auto root = new Statement();
        foreach (token; tokens) {
            root.children ~= new Expression(token.value);
        }
        return root;
    }
}

class CodeGenerator {
    string generate(ASTNode ast) {
        return generateRecursive(ast);
    }
    
    private string generateRecursive(ASTNode node) {
        string result = "// Generated code for: " ~ node.toString() ~ "\n";
        
        if (auto stmt = cast(Statement) node) {
            foreach (child; stmt.children) {
                result ~= generateRecursive(child);
            }
        }
        
        return result;
    }
}

void main(string[] args) {
    auto lexer = new Lexer();
    auto parser = new Parser();
    auto codegen = new CodeGenerator();
    
    string testInput = "hello world test input";
    auto tokens = lexer.tokenize(testInput);
    auto ast = parser.parse(tokens);
    auto code = codegen.generate(ast);
}
EOF

    echo "$temp_dir"
}

# Create and compile real project
project_dir=$(create_real_d_project)
echo "📁 Created test project at: $project_dir"

start_time=$(date +%s.%N)
cd "$project_dir"
if "$DMD_BINARY" src/main.d -of=test_app 2>/dev/null; then
    compile_result=0
    echo "✅ Real project compiled successfully"
else
    compile_result=1
    echo "❌ Real project compilation failed"
    # Debug: show compilation errors
    echo "Debug: Compilation errors:"
    "$DMD_BINARY" src/main.d -of=test_app || true
fi
end_time=$(date +%s.%N)

if [ $compile_result -eq 0 ]; then
    real_project_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")
else
    real_project_time="999.000000000"
fi

cd "$PROJECT_ROOT"
rm -rf "$project_dir"
echo "  \"real_project_compile_time\": $real_project_time," >> "$RESULTS_DIR/results.json"

# Test 3: Template Heavy Compilation
echo "🔧 Testing template-heavy compilation..."
template_dir=$(mktemp -d)
cd "$template_dir"

cat > template_test.d << 'EOF'
// Template heavy code
template Factorial(int n) {
    static if (n <= 1)
        enum Factorial = 1;
    else
        enum Factorial = n * Factorial!(n-1);
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
        enum IsPrime = CheckDivisor!3;
    }
}

// Force template instantiation at compile time
enum fact5 = Factorial!5;
enum fact10 = Factorial!10;
enum fact12 = Factorial!12;

enum prime7 = IsPrime!7;
enum prime11 = IsPrime!11;
enum prime13 = IsPrime!13;

void main() {
    // Use the computed values
    int[3] facts = [fact5, fact10, fact12];
    bool[3] primes = [prime7, prime11, prime13];
}
EOF

start_time=$(date +%s.%N)
if "$DMD_BINARY" template_test.d -of=template_test 2>/dev/null; then
    echo "✅ Template test compiled successfully"
    template_result=0
else
    echo "❌ Template test compilation failed"
    echo "Debug: Template compilation errors:"
    "$DMD_BINARY" template_test.d -of=template_test || true
    template_result=1
fi
end_time=$(date +%s.%N)

if [ $template_result -eq 0 ]; then
    template_stress_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")
else
    template_stress_time="999.000000000"
fi

cd "$PROJECT_ROOT"
rm -rf "$template_dir"
echo "  \"template_stress_time\": $template_stress_time," >> "$RESULTS_DIR/results.json"

# Test 4: CTFE Heavy Code
echo "⚡ Testing CTFE-heavy compilation..."
ctfe_dir=$(mktemp -d)
cd "$ctfe_dir"

cat > ctfe_test.d << 'EOF'
// CTFE heavy code
int[] generateData(int n) {
    int[] result;
    foreach (i; 0 .. n) {
        result ~= i * i;
    }
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

string generateCode(int n) {
    string result = "int[] compiledData = [";
    foreach (i; 0 .. n) {
        if (i > 0) result ~= ", ";
        result ~= intToString(i * i);
    }
    result ~= "];";
    return result;
}

// Force CTFE execution
enum computedData = generateData(100);
enum codeString = generateCode(50);

void main() {
    // Use the CTFE-computed data
    auto dataLen = computedData.length;
    
    // Mix in some generated code
    mixin(codeString);
    auto compiledLen = compiledData.length;
}
EOF

start_time=$(date +%s.%N)
if "$DMD_BINARY" ctfe_test.d -of=ctfe_test 2>/dev/null; then
    echo "✅ CTFE test compiled successfully"
    ctfe_result=0
else
    echo "❌ CTFE test compilation failed"
    echo "Debug: CTFE compilation errors:"
    "$DMD_BINARY" ctfe_test.d -of=ctfe_test || true
    ctfe_result=1
fi
end_time=$(date +%s.%N)

if [ $ctfe_result -eq 0 ]; then
    ctfe_stress_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")
else
    ctfe_stress_time="999.000000000"
fi

cd "$PROJECT_ROOT"
rm -rf "$ctfe_dir"
echo "  \"ctfe_stress_time\": $ctfe_stress_time," >> "$RESULTS_DIR/results.json"

# Test 5: DMD Self-Compile Performance (if source available)
if [ -f "src/dmd/mars.d" ] || [ -f "mars.d" ]; then
    echo "🔄 Testing DMD self-compilation..."
    start_time=$(date +%s.%N)
    timeout 600 make -f posix.mak -j1 > /dev/null 2>&1 || echo "Self-compile completed/timed out"
    end_time=$(date +%s.%N)
    self_compile_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")
    echo "  \"self_compile_time\": $self_compile_time," >> "$RESULTS_DIR/results.json"
fi

# Test 6: Large File Compilation
echo "📄 Testing large file compilation..."
large_file_dir=$(mktemp -d)
cd "$large_file_dir"

cat > large_file.d << 'EOF'
// Large file test with many functions and classes
module large_file;

EOF

# Generate many classes and functions
for i in {1..50}; do
    cat >> large_file.d << EOF
class TestClass$i {
    private int value$i;
    
    this(int val) { value$i = val; }
    
    int getValue() { return value$i; }
    void setValue(int val) { value$i = val; }
    
    int compute$i() {
        int result = 0;
        foreach (j; 0 .. value$i) {
            result += j * $i;
        }
        return result;
    }
}

int globalFunction$i(int param) {
    auto obj = new TestClass$i(param);
    return obj.compute$i();
}

EOF
done

cat >> large_file.d << 'EOF'
void main() {
    int total = 0;
EOF

for i in {1..50}; do
    echo "    total += globalFunction$i($i);" >> large_file.d
done

echo "}" >> large_file.d

start_time=$(date +%s.%N)
if "$DMD_BINARY" large_file.d -of=large_test 2>/dev/null; then
    echo "✅ Large file compiled successfully"
    large_file_result=0
else
    echo "❌ Large file compilation failed"
    large_file_result=1
fi
end_time=$(date +%s.%N)

if [ $large_file_result -eq 0 ]; then
    large_file_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")
else
    large_file_time="999.000000000"
fi

cd "$PROJECT_ROOT"
rm -rf "$large_file_dir"
echo "  \"large_file_compile_time\": $large_file_time," >> "$RESULTS_DIR/results.json"

# Get DMD binary size
dmd_size=$(stat -c%s "$DMD_BINARY" 2>/dev/null || stat -f%z "$DMD_BINARY" 2>/dev/null || echo "0")
echo "  \"dmd_size_bytes\": $dmd_size," >> "$RESULTS_DIR/results.json"

# Close JSON
sed -i '$ s/,$//' "$RESULTS_DIR/results.json"
echo "}" >> "$RESULTS_DIR/results.json"

echo "✅ Performance test completed!"
echo "📊 Results saved to: $RESULTS_DIR/results.json"

# Show summary
echo ""
echo "=== Performance Summary ==="
if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json
with open('$RESULTS_DIR/results.json') as f:
    data = json.load(f)

def fmt_time(t):
    return 'FAILED' if t == '999.000000000' else f'{float(t):.3f}s'

print(f\"Test Suite Duration: {fmt_time(data.get('test_suite_duration', '0'))}\")
print(f\"Real Project Compile: {fmt_time(data.get('real_project_compile_time', '0'))}\")
print(f\"Template Stress Test: {fmt_time(data.get('template_stress_time', '0'))}\")
print(f\"CTFE Stress Test: {fmt_time(data.get('ctfe_stress_time', '0'))}\")
print(f\"Large File Test: {fmt_time(data.get('large_file_compile_time', '0'))}\")
if 'self_compile_time' in data:
    print(f\"Self Compile: {fmt_time(data['self_compile_time'])}\")
print(f\"DMD Size: {int(data.get('dmd_size_bytes', 0)) / (1024*1024):.1f}MB\")
"
fi