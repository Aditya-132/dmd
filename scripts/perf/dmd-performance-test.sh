#!/bin/bash
# DMD Performance Test Script with comprehensive error handling
# Usage: ./dmd-performance-test.sh [baseline|pr]

set -e

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

# Format duration helper
format_duration() {
    local duration="$1"
    printf "%.9f" "$duration" | sed 's/^\./0./'
}

# Find DMD binary with comprehensive search
find_dmd() {
    local dmd_paths=(
        "generated/linux/release/64/dmd"
        "generated/linux/debug/64/dmd"
        "generated/osx/release/64/dmd"
        "generated/linux/64/dmd"
        "generated/windows/release/64/dmd.exe"
        "src/dmd"
        "dmd"
        "compiler/src/dmd"
        "build/dmd"
    )
    
    for path in "${dmd_paths[@]}"; do
        if [ -f "$PROJECT_ROOT/$path" ] && [ -x "$PROJECT_ROOT/$path" ]; then
            echo "$PROJECT_ROOT/$path"
            return 0
        fi
    done
    
    echo ""
    return 1
}

# Test compilation with comprehensive error reporting
test_compilation() {
    local test_name="$1"
    local source_files="$2"
    local output_file="$3"
    local timeout_sec="${4:-120}"
    
    log_info "Testing $test_name..."
    
    local start_time=$(date +%s.%N)
    local compile_result=0
    local error_output=""
    
    # Test compilation with timeout and comprehensive error capture
    if ! error_output=$(timeout "$timeout_sec" "$DMD_BINARY" $source_files -of="$output_file" -v 2>&1); then
        compile_result=1
        log_error "$test_name compilation failed"
        echo "Error details (last 15 lines):"
        echo "$error_output" | tail -15
        echo "---"
    else
        log_success "$test_name compiled successfully"
        # Cleanup generated files
        rm -f "$output_file" "$output_file.o"
    fi
    
    local end_time=$(date +%s.%N)
    
    if [ $compile_result -eq 0 ]; then
        format_duration "$(echo "$end_time - $start_time" | bc -l)"
    else
        echo "999.000000000"
    fi
}

# Test DMD with incremental complexity
test_dmd_incrementally() {
    log_info "Testing DMD with incremental complexity..."
    
    # Test 1: Minimal D program
    echo 'void main() {}' > /tmp/test_minimal.d
    if ! "$DMD_BINARY" /tmp/test_minimal.d -of=/tmp/test_minimal 2>/dev/null; then
        log_error "DMD cannot compile minimal D program"
        rm -f /tmp/test_minimal.d /tmp/test_minimal
        return 1
    fi
    rm -f /tmp/test_minimal.d /tmp/test_minimal
    log_success "Minimal compilation works"
    
    # Test 2: Basic language features
    cat > /tmp/test_basic.d << 'EOF'
struct Point { int x, y; }
class Test { int value; this(int v) { value = v; } }
void main() {
    auto p = Point(1, 2);
    auto t = new Test(42);
}
EOF
    if ! "$DMD_BINARY" /tmp/test_basic.d -of=/tmp/test_basic 2>/dev/null; then
        log_error "DMD cannot compile basic D features"
        rm -f /tmp/test_basic.d /tmp/test_basic
        return 1
    fi
    rm -f /tmp/test_basic.d /tmp/test_basic
    log_success "Basic language features work"
    
    return 0
}

echo "=== DMD Performance Test ($TEST_TYPE) ==="
cd "$PROJECT_ROOT"

# Initialize results JSON
{
    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"test_type\": \"$TEST_TYPE\","
    echo "  \"script_version\": \"2.0\","
    if git rev-parse --git-dir > /dev/null 2>&1; then
        echo "  \"commit\": \"$(git rev-parse HEAD)\","
        echo "  \"branch\": \"$(git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'detached')\","
        echo "  \"commit_message\": \"$(git log -1 --pretty=format:'%s' 2>/dev/null || echo 'unknown')\","
    fi
} > "$RESULTS_DIR/results.json"

# Find and verify DMD binary
log_info "Locating DMD binary..."
DMD_BINARY=$(find_dmd)
if [ -z "$DMD_BINARY" ]; then
    log_error "DMD binary not found!"
    echo "Searching for DMD files in common locations:"
    find . -name "*dmd*" -type f 2>/dev/null | head -20
    echo '  "error": "dmd_not_found"' >> "$RESULTS_DIR/results.json"
    echo '}' >> "$RESULTS_DIR/results.json"
    exit 1
fi

log_success "Using DMD: $DMD_BINARY"

# Verify DMD functionality incrementally
log_info "Verifying DMD functionality..."
if ! test_dmd_incrementally; then
    log_error "DMD failed incremental functionality tests"
    echo '  "error": "dmd_not_functional"' >> "$RESULTS_DIR/results.json"
    echo '}' >> "$RESULTS_DIR/results.json"
    exit 1
fi

# Check standard library availability
log_info "Checking standard library availability..."
echo 'import std.stdio; void main() { writeln("Hello, Phobos!"); }' > /tmp/test_phobos.d
if "$DMD_BINARY" /tmp/test_phobos.d -of=/tmp/test_phobos 2>/dev/null; then
    HAS_PHOBOS=true
    log_success "Standard library (Phobos) is available"
    rm -f /tmp/test_phobos /tmp/test_phobos.d
else
    HAS_PHOBOS=false
    log_warning "Standard library not available - using simplified tests"
    rm -f /tmp/test_phobos.d
fi

# Test 1: Basic compilation benchmark
log_info "Running basic compilation benchmark..."
temp_dir=$(mktemp -d)
cd "$temp_dir"

start_time=$(date +%s.%N)
success_count=0
total_files=15

for i in $(seq 1 $total_files); do
    cat > "test$i.d" << EOF
module test$i;

void test$i() { 
    int x = $i;
    int y = x * 2;
    int z = y + $i;
}

void main() { 
    test$i(); 
}
EOF
    
    if "$DMD_BINARY" "test$i.d" -of="test$i" 2>/dev/null; then
        success_count=$((success_count + 1))
        rm -f "test$i" "test$i.o"
    fi
    rm -f "test$i.d"
done

end_time=$(date +%s.%N)

if [ $success_count -eq $total_files ]; then
    basic_benchmark_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")
    log_success "Basic benchmark: $success_count/$total_files files compiled"
else
    basic_benchmark_time="999.000000000"
    log_warning "Basic benchmark: only $success_count/$total_files files compiled"
fi

cd "$PROJECT_ROOT"
rm -rf "$temp_dir"
echo "  \"basic_benchmark_time\": $basic_benchmark_time," >> "$RESULTS_DIR/results.json"

# Test 2: Real D project compilation
log_info "Testing real D project compilation..."
temp_dir=$(mktemp -d)
cd "$temp_dir"

cat > main.d << 'EOF'
module main;

struct Token {
    string type;
    string value;
    size_t line;
    size_t column;
    
    this(string t, string v, size_t l, size_t c = 0) {
        type = t; value = v; line = l; column = c;
    }
    
    bool isValid() const {
        return type.length > 0 && value.length > 0;
    }
}

interface ILexer {
    Token[] tokenize(string input);
    void reset();
}

class Lexer : ILexer {
    Token[] tokens;
    size_t currentLine = 1;
    size_t currentColumn = 1;
    
    override Token[] tokenize(string input) {
        Token[] result;
        
        foreach (i, char c; input) {
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
                // Simple identifier
                size_t start = i;
                while (i < input.length && 
                       ((input[i] >= 'a' && input[i] <= 'z') || 
                        (input[i] >= 'A' && input[i] <= 'Z') ||
                        (input[i] >= '0' && input[i] <= '9'))) {
                    i++;
                }
                result ~= Token("IDENTIFIER", input[start..i], currentLine, currentColumn);
                currentColumn += (i - start);
                i--; // Adjust for foreach increment
            } else if (c >= '0' && c <= '9') {
                result ~= Token("NUMBER", input[i..i+1], currentLine, currentColumn);
                currentColumn++;
            } else if (c == '\n') {
                currentLine++;
                currentColumn = 1;
            } else if (c == ' ' || c == '\t') {
                currentColumn++;
            } else {
                result ~= Token("OPERATOR", input[i..i+1], currentLine, currentColumn);
                currentColumn++;
            }
        }
        return result;
    }
    
    override void reset() {
        tokens = [];
        currentLine = 1;
        currentColumn = 1;
    }
}

abstract class ASTNode {
    abstract string toString() const;
    abstract string getType() const;
}

class Expression : ASTNode {
    string value;
    string expressionType;
    
    this(string v, string t = "literal") { 
        value = v; 
        expressionType = t;
    }
    
    override string toString() const { return value; }
    override string getType() const { return expressionType; }
}

class BinaryExpression : Expression {
    ASTNode left, right;
    string operator;
    
    this(ASTNode l, ASTNode r, string op) {
        super("", "binary");
        left = l; right = r; operator = op;
    }
    
    override string toString() const {
        return left.toString() ~ " " ~ operator ~ " " ~ right.toString();
    }
}

class Statement : ASTNode {
    ASTNode[] children;
    string statementType;
    
    this(string type = "compound") {
        statementType = type;
    }
    
    override string toString() const { return statementType ~ " statement"; }
    override string getType() const { return statementType; }
    
    void addChild(ASTNode child) {
        if (child !is null) {
            children ~= child;
        }
    }
    
    size_t getChildCount() const {
        return children.length;
    }
}

interface IParser {
    ASTNode parse(Token[] tokens);
}

class Parser : IParser {
    size_t currentToken = 0;
    Token[] tokens;
    
    override ASTNode parse(Token[] tokenArray) {
        tokens = tokenArray;
        currentToken = 0;
        
        auto root = new Statement("program");
        
        while (currentToken < tokens.length) {
            auto stmt = parseStatement();
            if (stmt !is null) {
                root.addChild(stmt);
            }
        }
        
        return root;
    }
    
    private Statement parseStatement() {
        if (currentToken >= tokens.length) return null;
        
        auto stmt = new Statement("expression");
        
        // Simple expression parsing
        while (currentToken < tokens.length && tokens[currentToken].type != "NEWLINE") {
            auto expr = new Expression(tokens[currentToken].value, tokens[currentToken].type);
            stmt.addChild(expr);
            currentToken++;
            
            if (currentToken >= tokens.length) break;
        }
        
        if (currentToken < tokens.length) currentToken++; // Skip newline
        
        return stmt.getChildCount() > 0 ? stmt : null;
    }
}

class CodeGenerator {
    string targetLanguage;
    
    this(string lang = "d") {
        targetLanguage = lang;
    }
    
    string generate(ASTNode ast) {
        if (ast is null) return "";
        
        string result = "// Generated " ~ targetLanguage ~ " code\n";
        result ~= "// AST Type: " ~ ast.getType() ~ "\n";
        result ~= generateNode(ast, 0);
        return result;
    }
    
    private string generateNode(ASTNode node, int indent) {
        if (node is null) return "";
        
        string indentStr = "";
        foreach (i; 0 .. indent) indentStr ~= "  ";
        
        string result = indentStr ~ "// " ~ node.toString() ~ "\n";
        
        // If it's a statement, generate children
        if (auto stmt = cast(Statement)node) {
            result ~= indentStr ~ "{\n";
            foreach (child; stmt.children) {
                result ~= generateNode(child, indent + 1);
            }
            result ~= indentStr ~ "}\n";
        }
        
        return result;
    }
}

class CompilerPipeline {
    ILexer lexer;
    IParser parser;
    CodeGenerator generator;
    
    this() {
        lexer = new Lexer();
        parser = new Parser();
        generator = new CodeGenerator();
    }
    
    string compile(string sourceCode) {
        lexer.reset();
        auto tokens = lexer.tokenize(sourceCode);
        auto ast = parser.parse(tokens);
        return generator.generate(ast);
    }
}

void main() {
    auto pipeline = new CompilerPipeline();
    
    string[] testPrograms = [
        "hello world program",
        "function calculate x y z",
        "class MyClass extends BaseClass",
        "if condition then action else alternative",
        "for each item in collection process item"
    ];
    
    foreach (i, program; testPrograms) {
        auto result = pipeline.compile(program);
        // Simulate some processing time
        foreach (j; 0 .. 100) {
            auto dummy = pipeline.compile("dummy " ~ cast(char)('a' + (j % 26)));
        }
    }
}
EOF

real_project_time=$(test_compilation "Real D Project" "main.d" "test_app" 180)
cd "$PROJECT_ROOT"
rm -rf "$temp_dir"
echo "  \"real_project_compile_time\": $real_project_time," >> "$RESULTS_DIR/results.json"

# Test 3: Template-heavy compilation
log_info "Testing template-heavy compilation..."
temp_dir=$(mktemp -d)
cd "$temp_dir"

cat > template_test.d << 'EOF'
module template_test;

// Mathematical templates
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
        enum IsPrime = CheckDivisor!(3);
    }
}

// Generic templates
template Max(T) {
    T Max(T a, T b) {
        return a > b ? a : b;
    }
}

template ArrayProcessor(T) {
    struct ArrayProcessor {
        T[] data;
        
        this(T[] initial) {
            data = initial;
        }
        
        T sum() {
            T result = T.init;
            foreach (item; data) {
                result += item;
            }
            return result;
        }
        
        T[] map(T delegate(T) func) {
            T[] result;
            foreach (item; data) {
                result ~= func(item);
            }
            return result;
        }
        
        T[] filter(bool delegate(T) predicate) {
            T[] result;
            foreach (item; data) {
                if (predicate(item)) {
                    result ~= item;
                }
            }
            return result;
        }
    }
}

// Force template instantiations
enum fact5 = Factorial!(5);
enum fact8 = Factorial!(8);
enum fact10 = Factorial!(10);

enum fib5 = Fibonacci!(5);
enum fib8 = Fibonacci!(8);
enum fib10 = Fibonacci!(10);

enum prime7 = IsPrime!(7);
enum prime11 = IsPrime!(11);
enum prime13 = IsPrime!(13);
enum prime17 = IsPrime!(17);

alias IntProcessor = ArrayProcessor!int;
alias FloatProcessor = ArrayProcessor!float;
alias MaxInt = Max!int;
alias MaxFloat = Max!float;

void main() {
    // Use template instantiations
    int factSum = fact5 + fact8 + fact10;
    int fibSum = fib5 + fib8 + fib10;
    bool anyPrime = prime7 || prime11 || prime13 || prime17;
    
    auto maxIntVal = MaxInt(10, 20);
    auto maxFloatVal = MaxFloat(1.5, 2.5);
    
    auto intProc = IntProcessor([1, 2, 3, 4, 5]);
    auto intSum = intProc.sum();
    
    auto floatProc = FloatProcessor([1.1, 2.2, 3.3]);
    auto floatSum = floatProc.sum();
}
EOF

template_stress_time=$(test_compilation "Template Heavy" "template_test.d" "template_test" 240)
cd "$PROJECT_ROOT"
rm -rf "$temp_dir"
echo "  \"template_stress_time\": $template_stress_time," >> "$RESULTS_DIR/results.json"

# Test 4: CTFE-heavy compilation
log_info "Testing CTFE-heavy compilation..."
temp_dir=$(mktemp -d)
cd "$temp_dir"

cat > ctfe_test.d << 'EOF'
module ctfe_test;

// CTFE mathematical functions
int[] generatePrimes(int limit) {
    int[] primes;
    
    foreach (n; 2 .. limit) {
        bool isPrime = true;
        foreach (p; primes) {
            if (p * p > n) break;
            if (n % p == 0) {
                isPrime = false;
                break;
            }
        }
        if (isPrime) {
            primes ~= n;
        }
    }
    return primes;
}

int[] generateSquares(int count) {
    int[] result;
    foreach (i; 0 .. count) {
        result ~= i * i;
    }
    return result;
}

int[] generateFibonacci(int count) {
    if (count == 0) return [];
    if (count == 1) return [0];
    
    int[] result = [0, 1];
    foreach (i; 2 .. count) {
        result ~= result[i-1] + result[i-2];
    }
    return result;
}

string generateLookupTable(int size) {
    string result = "static immutable string[] lookupTable = [\n";
    foreach (i; 0 .. size) {
        result ~= "  \"item" ~ cast(char)('0' + (i % 10)) ~ "\",\n";
    }
    result ~= "];";
    return result;
}

// Matrix operations at compile time
int[][] multiplyMatrices(int[][] a, int[][] b) {
    if (a.length == 0 || b.length == 0 || a[0].length != b.length) {
        return [];
    }
    
    int[][] result = new int[][](a.length, b[0].length);
    foreach (i; 0 .. a.length) {
        result[i] = new int[](b[0].length);
        foreach (j; 0 .. b[0].length) {
            result[i][j] = 0;
            foreach (k; 0 .. a[0].length) {
                result[i][j] += a[i][k] * b[k][j];
            }
        }
    }
    return result;
}

// Compile-time string processing
string reverseString(string input) {
    string result = "";
    foreach_reverse (c; input) {
        result ~= c;
    }
    return result;
}

string processText(string input) {
    string result = "";
    foreach (i, c; input) {
        if (i % 2 == 0) {
            if (c >= 'a' && c <= 'z') {
                result ~= cast(char)(c - 'a' + 'A'); // To uppercase
            } else {
                result ~= c;
            }
        } else {
            result ~= c;
        }
    }
    return result;
}

// Force CTFE execution with substantial computations
enum primes = generatePrimes(50);
enum squares = generateSquares(30);
enum fibonacci = generateFibonacci(20);
enum lookupCode = generateLookupTable(25);

enum matrix1 = [[1, 2, 3], [4, 5, 6], [7, 8, 9]];
enum matrix2 = [[9, 8, 7], [6, 5, 4], [3, 2, 1]];
enum matrixProduct = multiplyMatrices(matrix1, matrix2);

enum testString = "Hello World From CTFE Processing";
enum reversedString = reverseString(testString);
enum processedString = processText(testString);

// Computed constants
enum primeSum = {
    int sum = 0;
    foreach (p; primes) sum += p;
    return sum;
}();

enum squareSum = {
    int sum = 0;
    foreach (s; squares) sum += s;
    return sum;
}();

void main() {
    // Use all CTFE-computed values
    int totalPrimes = primes.length;
    int totalSquares = squares.length;
    int fibLast = fibonacci[$ - 1];
    
    int matrixSum = 0;
    foreach (row; matrixProduct) {
        foreach (val; row) {
            matrixSum += val;
        }
    }
    
    // String processing results
    string reversed = reversedString;
    string processed = processedString;
    
    // Computed sums
    int pSum = primeSum;
    int sSum = squareSum;
}
EOF

ctfe_stress_time=$(test_compilation "CTFE Heavy" "ctfe_test.d" "ctfe_test" 300)
cd "$PROJECT_ROOT"
rm -rf "$temp_dir"
echo "  \"ctfe_stress_time\": $ctfe_stress_time," >> "$RESULTS_DIR/results.json"

# Test 5: Large file compilation stress test
log_info "Testing large file compilation..."
temp_dir=$(mktemp -d)
cd "$temp_dir"

# Generate substantial D code
{
    echo "module large_file;"
    echo ""
    echo "// Large file stress test with realistic D patterns"
    echo ""
    
    # Generate enums
    echo "enum TokenType {"
    for i in $(seq 1 20); do
        echo "    Token$i,"
    done
    echo "}"
    echo ""
    
    # Generate interfaces
    for i in $(seq 1 15); do
        cat << INTEOF
interface IProcessor$i {
    int process$i(int input);
    bool validate$i(int input);
    string getName$i();
}

INTEOF
    done
    
    # Generate classes with inheritance and methods
    for i in $(seq 1 50); do
        base_class=$((i % 15 + 1))
        cat << CLASSEOF
class TestClass$i : IProcessor$base_class {
    private int value$i = $i;
    private string name$i = "TestClass$i";
    private int[] data$i;
    private bool initialized$i = false;
    
    this() {
        initialize$i();
    }
    
    this(int val) {
        value$i = val;
        initialize$i();
    }
    
    this(int val, string n) {
        value$i = val;
        name$i = n;
        initialize$i();
    }
    
    private void initialize$i() {
        data$i = new int[10];
        foreach (j; 0 .. 10) {
            data$i[j] = j * value$i;
        }
        initialized$i = true;
    }
    
    override int process$base_class(int input) {
        if (!initialized$i) initialize$i();
        
        int result = input + value$i;
        foreach (val; data$i) {
            result += val;
        }
        return result % 10000;
    }
    
    override bool validate$base_class(int input) {
        return input > 0 && input < 10000 && initialized$i;
    }
    
    override string getName$base_class() {
        return name$i;
    }
    
    // Additional methods
    int getValue() { return value$i; }
    void setValue(int val) { 
        value$i = val; 
        initialize$i(); // Reinitialize with new value
    }
    
    string getName() { return name$i; }
    void setName(string n) { name$i = n; }
    
    int compute() {
        if (!initialized$i) return 0;
        
        int result = 0;
        foreach (j; 0 .. data$i.length) {
            result += data$i[j] * (j + 1);
        }
        return result;
    }
    
    bool isValid() {
        return value$i > 0 && name$i.length > 0 && initialized$i;
    }
    
    void process() {
        if (isValid()) {
            int temp = compute();
            setValue(temp % 1000);
        }
    }
    
    int[] getData() {
        return data$i.dup;
    }
    
    void processData() {
        foreach (ref val; data$i) {
            val = (val * 2 + 1) % 1000;
        }
    }
}

int processClass$i() {
    auto obj = new TestClass$i();
    auto processor = cast(IProcessor$base_class)obj;
    
    obj.process();
    obj.processData();
    
    int result = 0;
    if (processor.validate$base_class(obj.getValue())) {
        result = processor.process$base_class(obj.getValue());
    }
    
    return result;
}

CLASSEOF
    done
    
    # Generate main function that uses all classes
    echo "void main() {"
    echo "    int total = 0;"
    echo "    int[] results = new int[50];"
    echo ""
    for i in $(seq 1 50); do
        echo "    results[$((i-1))] = processClass$i();"
    done
    echo ""
    echo "    // Process all results"
    echo "    foreach (i, result; results) {"
    echo "        total += result;"
    echo "        if (i % 10 == 0) {"
    echo "            total = total % 100000;"
    echo "        }"
    echo "    }"
    echo ""
    echo "    // Final computation to prevent optimization"
    echo "    foreach (i; 0 .. 10) {"
    echo "        total += processClass$((i % 50 + 1))();"
    echo "    }"
    echo "}"
} > large_file.d

large_file_time=$(test_compilation "Large File" "large_file.d" "large_test" 300)
cd "$PROJECT_ROOT"
rm -rf "$temp_dir"
echo "  \"large_file_compile_time\": $large_file_time," >> "$RESULTS_DIR/results.json"

# Test 6: Multi-module project compilation
log_info "Testing multi-module project compilation..."
temp_dir=$(mktemp -d)
cd "$temp_dir"

# Module 1: Core utilities
cat > core.d << 'EOF'
module core;

struct Vector2D {
    float x, y;
    
    this(float x, float y) {
        this.x = x;
        this.y = y;
    }
    
    Vector2D add(Vector2D other) {
        return Vector2D(x + other.x, y + other.y);
    }
    
    Vector2D multiply(float scalar) {
        return Vector2D(x * scalar, y * scalar);
    }
    
    float magnitude() {
        return x*x + y*y; // Simplified (no sqrt for compatibility)
    }
    
    Vector2D normalize() {
        float mag = magnitude();
        if (mag > 0) {
            return Vector2D(x/mag, y/mag);
        }
        return Vector2D(0, 0);
    }
}

interface Drawable {
    string draw();
    Vector2D getPosition();
    void setPosition(Vector2D pos);
}

interface Updatable {
    void update(float deltaTime);
}

abstract class GameObject : Drawable, Updatable {
    protected Vector2D position;
    protected string name;
    protected bool active = true;
    
    this(string n, Vector2D pos) {
        name = n;
        position = pos;
    }
    
    override Vector2D getPosition() { return position; }
    override void setPosition(Vector2D pos) { position = pos; }
    
    bool isActive() { return active; }
    void setActive(bool state) { active = state; }
    string getName() { return name; }
}

class BasicCalculator {
    static int add(int a, int b) { return a + b; }
    static int subtract(int a, int b) { return a - b; }
    static int multiply(int a, int b) { return a * b; }
    static int divide(int a, int b) { return b != 0 ? a / b : 0; }
    
    static int power(int base, int exp) {
        int result = 1;
        foreach (i; 0 .. exp) {
            result = multiply(result, base);
        }
        return result;
    }
    
    static float distance(Vector2D a, Vector2D b) {
        Vector2D diff = Vector2D(a.x - b.x, a.y - b.y);
        return diff.magnitude();
    }
}
EOF

# Module 2: Game entities
cat > entities.d << 'EOF'
module entities;
import core;

class Player : GameObject {
    private int health = 100;
    private int score = 0;
    private Vector2D velocity;
    
    this(string name, Vector2D startPos) {
        super(name, startPos);
        velocity = Vector2D(0, 0);
    }
    
    override string draw() {
        return "Player[" ~ name ~ "] at (" ~ 
               cast(char)('0' + cast(int)position.x % 10) ~ "," ~ 
               cast(char)('0' + cast(int)position.y % 10) ~ ")";
    }
    
    override void update(float deltaTime) {
        if (!active) return;
        
        // Update position based on velocity
        position = position.add(velocity.multiply(deltaTime));
        
        // Simple bounds checking
        if (position.x < 0) position.x = 0;
        if (position.y < 0) position.y = 0;
        if (position.x > 800) position.x = 800;
        if (position.y > 600) position.y = 600;
    }
    
    void moveBy(Vector2D delta) {
        velocity = velocity.add(delta);
    }
    
    void takeDamage(int damage) {
        health -= damage;
        if (health <= 0) {
            health = 0;
            active = false;
        }
    }
    
    void addScore(int points) {
        score += points;
    }
    
    int getHealth() { return health; }
    int getScore() { return score; }
    Vector2D getVelocity() { return velocity; }
}

class Enemy : GameObject {
    private int damage = 10;
    private float speed = 50.0f;
    private Player target;
    
    this(string name, Vector2D startPos, Player playerTarget) {
        super(name, startPos);
        target = playerTarget;
    }
    
    override string draw() {
        return "Enemy[" ~ name ~ "] chasing player";
    }
    
    override void update(float deltaTime) {
        if (!active || target is null) return;
        
        // Move towards player
        Vector2D targetPos = target.getPosition();
        Vector2D direction = Vector2D(
            targetPos.x - position.x,
            targetPos.y - position.y
        );
        
        // Normalize and apply speed
        float mag = direction.magnitude();
        if (mag > 0) {
            direction = direction.multiply(1.0f / mag);
            position = position.add(direction.multiply(speed * deltaTime));
        }
        
        // Check collision with player
        if (BasicCalculator.distance(position, targetPos) < 30) {
            target.takeDamage(damage);
        }
    }
    
    void setTarget(Player newTarget) {
        target = newTarget;
    }
    
    int getDamage() { return damage; }
    void setDamage(int d) { damage = d; }
}

class PowerUp : GameObject {
    private int value = 50;
    private bool collected = false;
    
    this(string name, Vector2D pos, int val) {
        super(name, pos);
        value = val;
    }
    
    override string draw() {
        return collected ? "PowerUp[collected]" : "PowerUp[available]";
    }
    
    override void update(float deltaTime) {
        if (collected) {
            active = false;
            return;
        }
        
        // Simple floating animation
        position.y += (deltaTime * 20); // Float up and down
    }
    
    bool tryCollect(Player player) {
        if (collected || !active) return false;
        
        if (BasicCalculator.distance(position, player.getPosition()) < 25) {
            collected = true;
            player.addScore(value);
            return true;
        }
        return false;
    }
    
    bool isCollected() { return collected; }
    int getValue() { return value; }
}
EOF

# Module 3: Game management
cat > game.d << 'EOF'
module game;
import core;
import entities;

class GameWorld {
    Player player;
    Enemy[] enemies;
    PowerUp[] powerUps;
    int worldWidth = 800;
    int worldHeight = 600;
    float gameTime = 0;
    
    this() {
        player = new Player("Hero", Vector2D(400, 300));
        initializeEnemies();
        initializePowerUps();
    }
    
    private void initializeEnemies() {
        foreach (i; 0 .. 15) {
            float x = (i * 50) % worldWidth;
            float y = (i * 37) % worldHeight;
            auto enemy = new Enemy("Enemy" ~ cast(char)('A' + i), Vector2D(x, y), player);
            enemies ~= enemy;
        }
    }
    
    private void initializePowerUps() {
        foreach (i; 0 .. 10) {
            float x = (i * 73) % worldWidth;
            float y = (i * 61) % worldHeight;
            auto powerUp = new PowerUp("PowerUp" ~ cast(char)('0' + i), Vector2D(x, y), (i + 1) * 10);
            powerUps ~= powerUp;
        }
    }
    
    void update(float deltaTime) {
        gameTime += deltaTime;
        
        // Update player
        if (player.isActive()) {
            player.update(deltaTime);
        }
        
        // Update enemies
        foreach (enemy; enemies) {
            if (enemy.isActive()) {
                enemy.update(deltaTime);
            }
        }
        
        // Update power-ups and check collection
        foreach (powerUp; powerUps) {
            if (powerUp.isActive()) {
                powerUp.update(deltaTime);
                powerUp.tryCollect(player);
            }
        }
        
        // Spawn new enemies periodically
        if (cast(int)gameTime % 30 == 0) {
            spawnNewEnemy();
        }
    }
    
    private void spawnNewEnemy() {
        if (enemies.length < 20) {
            float x = gameTime % worldWidth;
            float y = (gameTime * 1.7f) % worldHeight;
            auto newEnemy = new Enemy("Spawned", Vector2D(x, y), player);
            enemies ~= newEnemy;
        }
    }
    
    void render() {
        // Simulate rendering all objects
        string[] renderBuffer;
        
        if (player.isActive()) {
            renderBuffer ~= player.draw();
        }
        
        foreach (enemy; enemies) {
            if (enemy.isActive()) {
                renderBuffer ~= enemy.draw();
            }
        }
        
        foreach (powerUp; powerUps) {
            if (powerUp.isActive()) {
                renderBuffer ~= powerUp.draw();
            }
        }
    }
    
    int getActiveEnemyCount() {
        int count = 0;
        foreach (enemy; enemies) {
            if (enemy.isActive()) count++;
        }
        return count;
    }
    
    int getAvailablePowerUpCount() {
        int count = 0;
        foreach (powerUp; powerUps) {
            if (powerUp.isActive() && !powerUp.isCollected()) count++;
        }
        return count;
    }
    
    bool isGameOver() {
        return !player.isActive() || getActiveEnemyCount() == 0;
    }
}

class GameManager {
    GameWorld world;
    bool running = true;
    int frameCount = 0;
    
    this() {
        world = new GameWorld();
    }
    
    void gameLoop() {
        float deltaTime = 1.0f / 60.0f; // 60 FPS
        
        foreach (frame; 0 .. 1000) { // Simulate 1000 frames
            if (!running || world.isGameOver()) break;
            
            world.update(deltaTime);
            world.render();
            frameCount++;
            
            // Game logic
            if (frameCount % 100 == 0) {
                processGameState();
            }
        }
    }
    
    private void processGameState() {
        // Process game state every 100 frames
        int score = world.player.getScore();
        int health = world.player.getHealth();
        int enemies = world.getActiveEnemyCount();
        int powerUps = world.getAvailablePowerUpCount();
        
        // Make some decisions based on state
        if (health < 30 && powerUps > 0) {
            // Try to collect power-ups
        }
        
        if (enemies > 15) {
            // Too many enemies, spawn fewer
        }
    }
    
    void stop() {
        running = false;
    }
    
    int getFrameCount() { return frameCount; }
    bool isRunning() { return running; }
}

CLASSEOF
    done
    
    # Generate main function
    echo "void main() {"
    echo "    auto gameManager = new GameManager();"
    echo "    gameManager.gameLoop();"
    echo ""
    echo "    // Process all test classes"
    echo "    int total = 0;"
    for i in $(seq 1 50); do
        echo "    total += processClass$i();"
    done
    echo ""
    echo "    // Additional processing to stress test"
    echo "    foreach (i; 0 .. 100) {"
    echo "        int classIndex = (i % 50) + 1;"
    echo "        // Simulate dynamic dispatch"
    echo "        if (classIndex <= 25) {"
    for j in $(seq 1 25); do
        echo "            if (classIndex == $j) total += processClass$j();"
    done
    echo "        } else {"
    for j in $(seq 26 50); do
        echo "            if (classIndex == $j) total += processClass$j();"
    done
    echo "        }"
    echo "    }"
    echo ""
    echo "    // Final result processing"
    echo "    total = total % 1000000;"
    echo "}"
} > large_file.d

large_file_time=$(test_compilation "Large File" "large_file.d" "large_test" 300)
cd "$PROJECT_ROOT"
rm -rf "$temp_dir"
echo "  \"large_file_compile_time\": $large_file_time," >> "$RESULTS_DIR/results.json"

# Test 6: Multi-module project
log_info "Testing multi-module project compilation..."
temp_dir=$(mktemp -d)
cd "$temp_dir"

# Module 1: Math utilities
cat > math_utils.d << 'EOF'
module math_utils;

struct Point {
    int x, y;
    
    this(int x, int y) {
        this.x = x;
        this.y = y;
    }
    
    int distanceSquared(Point other) {
        int dx = x - other.x;
        int dy = y - other.y;
        return dx*dx + dy*dy;
    }
    
    Point add(Point other) {
        return Point(x + other.x, y + other.y);
    }
    
    Point scale(int factor) {
        return Point(x * factor, y * factor);
    }
}

class MathOperations {
    static int gcd(int a, int b) {
        while (b != 0) {
            int temp = b;
            b = a % b;
            a = temp;
        }
        return a;
    }
    
    static int lcm(int a, int b) {
        return (a * b) / gcd(a, b);
    }
    
    static int factorial(int n) {
        if (n <= 1) return 1;
        return n * factorial(n - 1);
    }
    
    static bool isPrime(int n) {
        if (n < 2) return false;
        if (n == 2) return true;
        if (n % 2 == 0) return false;
        
        for (int i = 3; i * i <= n; i += 2) {
            if (n % i == 0) return false;
        }
        return true;
    }
}
EOF

# Module 2: Data structures
cat > data_structures.d << 'EOF'
module data_structures;
import math_utils;

class DynamicArray(T) {
    private T[] data;
    private size_t count = 0;
    
    this(size_t initialCapacity = 10) {
        data = new T[initialCapacity];
    }
    
    void add(T item) {
        if (count >= data.length) {
            resize(data.length * 2);
        }
        data[count++] = item;
    }
    
    T get(size_t index) {
        if (index >= count) {
            throw new Exception("Index out of bounds");
        }
        return data[index];
    }
    
    void set(size_t index, T item) {
        if (index >= count) {
            throw new Exception("Index out of bounds");
        }
        data[index] = item;
    }
    
    private void resize(size_t newCapacity) {
        T[] newData = new T[newCapacity];
        foreach (i; 0 .. count) {
            newData[i] = data[i];
        }
        data = newData;
    }
    
    size_t length() { return count; }
    bool empty() { return count == 0; }
    
    void clear() {
        count = 0;
    }
    
    T[] toArray() {
        return data[0 .. count].dup;
    }
}

class LinkedListNode(T) {
    T data;
    LinkedListNode!T next;
    
    this(T value) {
        data = value;
        next = null;
    }
}

class LinkedList(T) {
    private LinkedListNode!T head;
    private size_t count = 0;
    
    void add(T item) {
        auto newNode = new LinkedListNode!T(item);
        newNode.next = head;
        head = newNode;
        count++;
    }
    
    bool remove(T item) {
        if (head is null) return false;
        
        if (head.data == item) {
            head = head.next;
            count--;
            return true;
        }
        
        auto current = head;
        while (current.next !is null) {
            if (current.next.data == item) {
                current.next = current.next.next;
                count--;
                return true;
            }
            current = current.next;
        }
        return false;
    }
    
    bool contains(T item) {
        auto current = head;
        while (current !is null) {
            if (current.data == item) return true;
            current = current.next;
        }
        return false;
    }
    
    size_t length() { return count; }
    bool empty() { return head is null; }
    
    T[] toArray() {
        T[] result = new T[count];
        auto current = head;
        size_t index = 0;
        
        while (current !is null && index < count) {
            result[index++] = current.data;
            current = current.next;
        }
        return result;
    }
}

class HashMap(K, V) {
    private struct Entry {
        K key;
        V value;
        bool used = false;
    }
    
    private Entry[] buckets;
    private size_t count = 0;
    
    this(size_t initialSize = 16) {
        buckets = new Entry[initialSize];
    }
    
    private size_t hash(K key) {
        // Simple hash function
        static if (is(K == int)) {
            return (cast(size_t)key * 2654435761U) % buckets.length;
        } else static if (is(K == string)) {
            size_t hash = 5381;
            foreach (c; key) {
                hash = ((hash << 5) + hash) + c;
            }
            return hash % buckets.length;
        } else {
            return cast(size_t)key % buckets.length;
        }
    }
    
    void put(K key, V value) {
        size_t index = hash(key);
        size_t originalIndex = index;
        
        do {
            if (!buckets[index].used || buckets[index].key == key) {
                if (!buckets[index].used) count++;
                buckets[index].key = key;
                buckets[index].value = value;
                buckets[index].used = true;
                return;
            }
            index = (index + 1) % buckets.length;
        } while (index != originalIndex);
        
        // Table is full, should resize but keeping simple for test
    }
    
    V get(K key) {
        size_t index = hash(key);
        size_t originalIndex = index;
        
        do {
            if (buckets[index].used && buckets[index].key == key) {
                return buckets[index].value;
            }
            if (!buckets[index].used) break;
            index = (index + 1) % buckets.length;
        } while (index != originalIndex);
        
        throw new Exception("Key not found");
    }
    
    bool containsKey(K key) {
        try {
            get(key);
            return true;
        } catch (Exception) {
            return false;
        }
    }
    
    size_t length() { return count; }
}
EOF

# Module 3: Main application
cat > main.d << 'EOF'
module main;
import math_utils;
import data_structures;
import entities;

class Application {
    Player player;
    DynamicArray!Enemy enemies;
    LinkedList!PowerUp powerUps;
    HashMap!(string, int) gameStats;
    MathOperations mathOps;
    
    this() {
        initializeGame();
    }
    
    private void initializeGame() {
        player = new Player("MainPlayer", Point(100, 100));
        enemies = new DynamicArray!Enemy();
        powerUps = new LinkedList!PowerUp();
        gameStats = new HashMap!(string, int)();
        mathOps = new MathOperations();
        
        // Initialize game statistics
        gameStats.put("score", 0);
        gameStats.put("level", 1);
        gameStats.put("enemies_defeated", 0);
        gameStats.put("powerups_collected", 0);
    }
    
    void runGameSimulation() {
        log_info("Starting game simulation...");
        
        // Create enemies
        foreach (i; 0 .. 20) {
            Point enemyPos = Point((i * 40) % 800, (i * 30) % 600);
            auto enemy = new Enemy("Enemy" ~ cast(char)('A' + (i % 26)), enemyPos, player);
            enemies.add(enemy);
        }
        
        // Create power-ups
        foreach (i; 0 .. 15) {
            Point powerUpPos = Point((i * 55) % 800, (i * 45) % 600);
            auto powerUp = new PowerUp("PowerUp" ~ cast(char)('0' + (i % 10)), powerUpPos, (i + 1) * 5);
            powerUps.add(powerUp);
        }
        
        // Simulate game frames
        float deltaTime = 1.0f / 60.0f;
        foreach (frame; 0 .. 3000) { // 50 seconds at 60 FPS
            updateGameState(deltaTime);
            
            if (frame % 100 == 0) {
                processStatistics();
            }
        }
        
        log_success("Game simulation completed");
    }
    
    private void updateGameState(float deltaTime) {
        // Update player
        if (player.isActive()) {
            player.update(deltaTime);
            
            // Simple AI movement
            Point playerPos = player.getPosition();
            player.moveBy(Point(
                (frameCount % 10 - 5),
                ((frameCount * 3) % 10 - 5)
            ));
        }
        
        // Update all enemies
        foreach (i; 0 .. enemies.length()) {
            auto enemy = enemies.get(i);
            if (enemy.isActive()) {
                enemy.update(deltaTime);
            }
        }
        
        // Update power-ups
        auto powerUpArray = powerUps.toArray();
        foreach (powerUp; powerUpArray) {
            if (powerUp.isActive()) {
                powerUp.update(deltaTime);
            }
        }
        
        // Mathematical processing
        processMathematicalOperations();
    }
    
    private void processMathematicalOperations() {
        // Perform various mathematical operations
        int currentScore = gameStats.get("score");
        int level = gameStats.get("level");
        
        // Prime number calculations
        int primeCount = 0;
        foreach (i; level * 10 .. (level + 1) * 10) {
            if (MathOperations.isPrime(i)) {
                primeCount++;
            }
        }
        
        // Factorial calculations
        int factorialSum = 0;
        foreach (i; 1 .. 8) {
            factorialSum += MathOperations.factorial(i);
        }
        
        // GCD/LCM calculations
        int gcdResult = MathOperations.gcd(currentScore, level * 100);
        int lcmResult = MathOperations.lcm(currentScore + 1, level * 50);
        
        // Update statistics
        gameStats.put("math_operations", primeCount + factorialSum + gcdResult + lcmResult);
    }
    
    private void processStatistics() {
        // Update game statistics
        int score = player.getScore();
        int health = player.getHealth();
        
        gameStats.put("score", score);
        gameStats.put("health", health);
        
        // Calculate derived statistics
        int enemiesAlive = 0;
        foreach (i; 0 .. enemies.length()) {
            if (enemies.get(i).isActive()) {
                enemiesAlive++;
            }
        }
        
        gameStats.put("enemies_alive", enemiesAlive);
        
        // Performance metrics
        if (gameStats.containsKey("math_operations")) {
            int mathOps = gameStats.get("math_operations");
            gameStats.put("performance_score", mathOps * score / 1000);
        }
    }
    
    private int frameCount = 0;
}

void main() {
    auto app = new Application();
    app.runGameSimulation();
    
    // Additional stress testing
    auto mathOps = new MathOperations();
    
    // Mathematical stress test
    int mathResults = 0;
    foreach (i; 1 .. 50) {
        mathResults += MathOperations.factorial(i % 8 + 1);
        
        if (MathOperations.isPrime(i)) {
            mathResults += i;
        }
        
        mathResults += MathOperations.gcd(i, i + 7);
        mathResults += MathOperations.lcm(i, i + 3);
    }
    
    // Data structure stress test
    auto intArray = new DynamicArray!int();
    auto intList = new LinkedList!int();
    auto intMap = new HashMap!(int, string)();
    
    foreach (i; 0 .. 100) {
        intArray.add(i * i);
        intList.add(i);
        intMap.put(i, "value" ~ cast(char)('0' + (i % 10)));
    }
    
    // Process data structures
    int arraySum = 0;
    foreach (i; 0 .. intArray.length()) {
        arraySum += intArray.get(i);
    }
    
    auto listArray = intList.toArray();
    int listSum = 0;
    foreach (val; listArray) {
        listSum += val;
    }
    
    // Point calculations
    Point[] points;
    foreach (i; 0 .. 50) {
        points ~= Point(i, i * 2);
    }
    
    int totalDistance = 0;
    foreach (i; 0 .. points.length - 1) {
        totalDistance += points[i].distanceSquared(points[i + 1]);
    }
}
EOF

multi_module_time=$(test_compilation "Multi-Module" "main.d math_utils.d data_structures.d entities.d game.d" "multi_test" 240)
cd "$PROJECT_ROOT"
rm -rf "$temp_dir"
echo "  \"multi_module_compile_time\": $multi_module_time," >> "$RESULTS_DIR/results.json"

# Test 7: DMD Self-compilation (if source available)
if [ -f "src/dmd/mars.d" ] || [ -f "compiler/src/dmd/mars.d" ] || [ -d "src" ] || [ -f "dmd.conf" ]; then
    log_info "Testing DMD self-compilation..."
    
    # Save current state
    current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    
    start_time=$(date +%s.%N)
    self_compile_success=false
    
    log_info "Attempting DMD self-compilation..."
    
    # Clean before self-compile attempt
    make clean > /dev/null 2>&1 || true
    
    # Try different build approaches with comprehensive timeout
    if timeout 900 make -j1 HOST_DMD="$HOST_DMD" AUTO_BOOTSTRAP=1 > /dev/null 2>&1; then
        self_compile_success=true
        log_success "Self-compilation via default Makefile succeeded"
    elif timeout 900 make -f posix.mak -j1 HOST_DMD="$HOST_DMD" > /dev/null 2>&1; then
        self_compile_success=true
        log_success "Self-compilation via posix.mak succeeded"
    elif timeout 900 make -f Makefile -j1 HOST_DMD="$HOST_DMD" > /dev/null 2>&1; then
        self_compile_success=true
        log_success "Self-compilation via explicit Makefile succeeded"
    else
        log_warning "Self-compilation failed or timed out after 15 minutes"
    fi
    
    end_time=$(date +%s.%N)
    
    if [ "$self_compile_success" = true ]; then
        self_compile_time=$(format_duration "$(echo "$end_time - $start_time" | bc -l)")
    else
        self_compile_time="999.000000000"
    fi
    
    echo "  \"self_compile_time\": $self_compile_time," >> "$RESULTS_DIR/results.json"
fi
