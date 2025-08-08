// Template instantiation stress test
module template_stress;

import std.stdio;
import std.meta;
import std.traits;
import std.conv;

// Recursive template stress
template RecursiveTemplate(int N) {
    static if (N > 0) {
        alias RecursiveTemplate = AliasSeq!(int, RecursiveTemplate!(N-1));
    } else {
        alias RecursiveTemplate = AliasSeq!();
    }
}

// Template with many parameters
template MultiParamTemplate(T, int N, string S, bool B) {
    static if (B && N > 0) {
        enum MultiParamTemplate = S ~ " " ~ T.stringof ~ " " ~ N.to!string;
    } else {
        enum MultiParamTemplate = "default";
    }
}

// Heavy CTFE computation
string generateLargeFunction(int numParams) {
    string result = "void generatedFunction(";
    
    foreach (i; 0..numParams) {
        if (i > 0) result ~= ", ";
        result ~= "int param" ~ i.to!string;
    }
    
    result ~= ") {\n";
    
    foreach (i; 0..numParams) {
        result ~= "    int var" ~ i.to!string ~ " = param" ~ 
                  i.to!string ~ " * 2;\n";
    }
    
    result ~= "}\n";
    return result;
}

void main() {
    // Test recursive templates
    alias TestAlias = RecursiveTemplate!50;
    writeln("Recursive template instantiated with ", TestAlias.length, " elements");
    
    // Test multi-parameter templates
    enum result1 = MultiParamTemplate!(int, 42, "test", true);
    enum result2 = MultiParamTemplate!(string, 0, "other", false);
    writeln("Multi-param results: ", result1, ", ", result2);
    
    // Test CTFE generation
    mixin(generateLargeFunction(20));
    writeln("Generated function compiled successfully");
}