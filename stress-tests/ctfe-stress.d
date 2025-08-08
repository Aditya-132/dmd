// CTFE-heavy stress test
module ctfe_stress;

import std.stdio;
import std.conv;
import std.algorithm;
import std.array;
import std.range;
import std.string;

// Compile-time array generation
int[] generateArray(int size) {
    int[] result;
    result.reserve(size);
    
    foreach (i; 0..size) {
        result ~= (i * i) % 1000;
    }
    
    return result;
}

// Compile-time string processing
string processStrings(string[] inputs) {
    string result = "";
    
    foreach (input; inputs) {
        result ~= input.toUpper();
        result ~= "_PROCESSED ";
    }
    
    return result;
}

// Compile-time fibonacci
int fibonacciCTFE(int n) {
    if (n <= 1) return n;
    
    int a = 0, b = 1;
    foreach (i; 2..n+1) {
        int temp = a + b;
        a = b;
        b = temp;
    }
    return b;
}

void main() {
    // Large compile-time array
    enum largeArray = generateArray(1000);
    writeln("Generated array length: ", largeArray.length);
    writeln("First 10 elements: ", largeArray[0..10]);
    
    // Compile-time string processing
    enum processedString = processStrings([
        "hello", "world", "dlang", "compiler", "performance",
        "test", "stress", "ctfe", "template", "mixin"
    ]);
    writeln("Processed string: ", processedString);
    
    // Compile-time fibonacci sequence
    enum fib30 = fibonacciCTFE(30);
    writeln("30th Fibonacci number: ", fib30);
    
    // Compile-time range operations
    enum squares = iota(1, 100)
                  .map!(x => x * x)
                  .filter!(x => x % 2 == 0)
                  .array;
    writeln("Even squares count: ", squares.length);
}