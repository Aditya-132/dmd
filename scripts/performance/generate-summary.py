#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

def format_duration(seconds):
    """Format duration in a human-readable way."""
    if seconds < 1:
        return f"{seconds*1000:.1f}ms"
    elif seconds < 60:
        return f"{seconds:.2f}s"
    else:
        minutes = int(seconds // 60)
        secs = seconds % 60
        return f"{minutes}m {secs:.1f}s"

def format_size(bytes_val):
    """Format file size in human-readable way."""
    if bytes_val < 1024:
        return f"{bytes_val}B"
    elif bytes_val < 1024*1024:
        return f"{bytes_val/1024:.1f}KB"
    else:
        return f"{bytes_val/(1024*1024):.1f}MB"

def main():
    script_dir = Path(__file__).parent
    project_root = script_dir.parent.parent
    results_file = project_root / "perf-results" / "results.json"
    summary_file = project_root / "perf-results" / "summary.md"
    
    if not results_file.exists():
        print("Results file not found!")
        return 1
    
    with open(results_file, 'r') as f:
        results = json.load(f)
    
    # Generate markdown summary
    summary = ["# 🚀 Performance Test Results\n"]
    
    # Basic info
    summary.append(f"**Commit:** `{results.get('commit', 'unknown')[:8]}`")
    summary.append(f"**Timestamp:** {results.get('timestamp', 'unknown')}")
    summary.append("")
    
    # Test results
    summary.append("## 📊 Performance Metrics\n")
    
    # Test suite duration
    if 'test_suite_duration' in results:
        duration = format_duration(results['test_suite_duration'])
        summary.append(f"- **Test Suite Duration:** {duration}")
    
    # Compiler size
    if 'compiler_size_bytes' in results:
        size = format_size(results['compiler_size_bytes'])
        summary.append(f"- **Compiler Size:** {size}")
    
    # Hello world results
    if 'hello_world' in results:
        hw = results['hello_world']
        summary.append(f"- **Hello World Compile Time:** {format_duration(hw.get('compile_time_seconds', 0))}")
        summary.append(f"- **Hello World Binary Size:** {format_size(hw.get('binary_size_bytes', 0))}")
        summary.append(f"- **Hello World Optimized Compile Time:** {format_duration(hw.get('optimized_compile_time_seconds', 0))}")
        summary.append(f"- **Hello World Optimized Binary Size:** {format_size(hw.get('optimized_binary_size_bytes', 0))}")
    
    # Complex project results
    if 'complex_project' in results:
        cp = results['complex_project']
        summary.append(f"- **Complex Project Compile Time:** {format_duration(cp.get('compile_time_seconds', 0))}")
        summary.append(f"- **Complex Project Binary Size:** {format_size(cp.get('binary_size_bytes', 0))}")
    
    summary.append("")
    summary.append("---")
    summary.append("*Performance regression test completed successfully* ✅")
    
    # Write summary
    with open(summary_file, 'w') as f:
        f.write('\n'.join(summary))
    
    print("Summary generated successfully!")
    return 0

if __name__ == "__main__":
    sys.exit(main())