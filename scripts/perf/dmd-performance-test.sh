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
    
    # Main module
    cat > src/main.d << 'EOF'
import std.stdio;
import std.algorithm;
import std.range;
import std.container;
import std.typecons;
import core.lexer;
import util.helpers;
import parser.ast;
import backend.codegen;

void main(string[] args) {
    auto lexer = new Lexer();
    auto parser = new Parser();
    auto codegen = new CodeGenerator();
    
    writeln("Processing ", args.length, " files...");
    
    foreach (arg; args) {
        auto tokens = lexer.tokenize(arg);
        auto ast = parser.parse(tokens);
        auto code = codegen.generate(ast);
        writeln("Generated code for: ", arg);
    }
}
EOF

    # Lexer module
    cat > src/core/lexer.d << 'EOF'
module core.lexer;
import std.array;
import std.algorithm;
import std.string;

struct Token {
    string type;
    string value;
    size_t line;
}

class Lexer {
    Token[] tokenize(string input) {
        Token[] tokens;
        auto lines = input.split('\n');
        
        foreach (i, line; lines) {
            auto words = line.split();
            foreach (word; words) {
                tokens ~= Token("WORD", word, i + 1);
            }
        }
        return tokens;
    }
}
EOF

    # Helper utilities
    cat > src/util/helpers.d << 'EOF'
module util.helpers;
import std.traits;
import std.meta;
import std.conv;

template isNumeric(T) {
    enum isNumeric = is(T : long) || is(T : real);
}

auto convertTo(T, U)(U value) if (isNumeric!T && isNumeric!U) {
    return value.to!T;
}

mixin template Singleton() {
    private static typeof(this) _instance;
    
    static typeof(this) instance() {
        if (_instance is null) {
            _instance = new typeof(this)();
        }
        return _instance;
    }
}
EOF

    # Parser AST
    cat > src/parser/ast.d << 'EOF'
module parser.ast;
import core.lexer;
import std.variant;

abstract class ASTNode {
    abstract override string toString();
}

class Expression : ASTNode {
    Variant value;
    this(Variant v) { value = v; }
    override string toString() { return value.toString(); }
}

class Statement : ASTNode {
    ASTNode[] children;
    override string toString() { return "Statement"; }
}

class Parser {
    ASTNode parse(Token[] tokens) {
        auto root = new Statement();
        foreach (token; tokens) {
            root.children ~= new Expression(Variant(token.value));
        }
        return root;
    }
}
EOF

    # Code generator
    cat > src/backend/codegen.d << 'EOF'
module backend.codegen;
import parser.ast;
import std.array;
import std.algorithm;

class CodeGenerator {
    string generate(ASTNode ast) {
        return generateRecursive(ast);
    }
    
    private string generateRecursive(ASTNode node) {
        auto result = appender!string;
        result.put("// Generated code for: ");
        result.put(node.toString());
        result.put("\n");
        
        if (auto stmt = cast(Statement) node) {
            foreach (child; stmt.children) {
                result.put(generateRecursive(child));
            }
        }
        
        return result.data;
    }
}
EOF

    echo "$temp_dir"
}

# Create and compile real project
project_dir=$(create_real_d_project)
echo "📁 Created test project at: $project_dir"

start_time=$(date +%s.%N)
cd "$project_dir"
if "$DMD_BINARY" -I=src src/main.d src/core/lexer.d src/util/helpers.d src/parser/ast.d src/backend/codegen.d -of=test_app 2>/dev/null; then
    compile_result=0
else
    compile_result=1
fi
end_time=$(date +%s.%N)

if [ $compile_result -eq 0 ]; then
    real_project_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")
    echo "✅ Real project compiled successfully in ${real_project_time}s"
else
    real_project_time="999.000000000"
    echo "❌ Real project compilation failed"
fi

cd "$PROJECT_ROOT"
rm -rf "$project_dir"
echo "  \"real_project_compile_time\": $real_project_time," >> "$RESULTS_DIR/results.json"

# Test 3: Template Heavy Compilation
echo "🔧 Testing template-heavy compilation..."
template_dir=$(mktemp -d)
cd "$template_dir"

cat > template_test.d << 'EOF'
import std.stdio;
import std.traits;
import std.meta;

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

void main() {
    writeln("Computing factorials and primes...");
    static foreach (i; 1 .. 15) {
        writeln("Factorial of ", i, " = ", Factorial!i);
        writeln("Is ", i, " prime? ", IsPrime!i);
    }
}
EOF

start_time=$(date +%s.%N)
if "$DMD_BINARY" template_test.d -of=template_test 2>/dev/null; then
    echo "✅ Template test compiled successfully"
else
    echo "❌ Template test compilation failed"
fi
end_time=$(date +%s.%N)
template_stress_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")

cd "$PROJECT_ROOT"
rm -rf "$template_dir"
echo "  \"template_stress_time\": $template_stress_time," >> "$RESULTS_DIR/results.json"

# Test 4: CTFE Heavy Code
echo "⚡ Testing CTFE-heavy compilation..."
ctfe_dir=$(mktemp -d)
cd "$ctfe_dir"

cat > ctfe_test.d << 'EOF'
import std.stdio;
import std.array;
import std.algorithm;
import std.conv;

string generateCode(int n) {
    string result = "int[] data = [";
    foreach (i; 0 .. n) {
        if (i > 0) result ~= ", ";
        result ~= (i * i).to!string;
    }
    result ~= "];";
    return result;
}

string processData() {
    auto numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    auto result = numbers.map!(x => x * x)
                        .filter!(x => x > 10)
                        .array
                        .to!string;
    return "auto processed = " ~ result ~ ";";
}

void main() {
    mixin(generateCode(1000));
    mixin(processData());
    writeln("Generated ", data.length, " elements");
    writeln("Processed data ready");
}
EOF

start_time=$(date +%s.%N)
if "$DMD_BINARY" ctfe_test.d -of=ctfe_test 2>/dev/null; then
    echo "✅ CTFE test compiled successfully"
else
    echo "❌ CTFE test compilation failed"
fi
end_time=$(date +%s.%N)
ctfe_stress_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")

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

# Get DMD binary size
dmd_size=$(stat -c%s "$DMD_BINARY" 2>/dev/null || stat -f%z "$DMD_BINARY" 2>/dev/null || echo "0")
echo "  \"dmd_size_bytes\": $dmd_size," >> "$RESULTS_DIR/results.json"

# Close JSON
sed -i '$ s/,$//' "$RESULTS_DIR/results.json"
echo "}" >> "$RESULTS_DIR/results.json"

echo "✅ Performance test completed!"
echo "📊 Results saved to: $RESULTS_DIR/results.json"