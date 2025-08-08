#!/usr/bin/env python3
import json
import os
import sys
import subprocess
from pathlib import Path

def get_baseline_results():
    """Get baseline results by checking out master branch."""
    current_branch = subprocess.check_output(['git', 'branch', '--show-current']).decode().strip()
    current_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD']).decode().strip()
    
    try:
        subprocess.run(['git', 'checkout', 'master'], check=True, capture_output=True)
        subprocess.run(['make', 'clean'], check=True, capture_output=True)
        subprocess.run(['make', '-j4', '-C', 'src'], check=True, capture_output=True)
        subprocess.run(['./scripts/performance/run-tests.sh'], check=True)

        with open('perf-results/results.json', 'r') as f:
            baseline_results = json.load(f)

        return baseline_results

    finally:
        subprocess.run(['git', 'checkout', current_commit], check=True, capture_output=True)

def compare_results(current, baseline):
    """Compare current results with baseline."""
    comparison = {
        'improvements': [],
        'regressions': [],
        'status': 'unknown'
    }

    # Compare test suite duration
    if 'test_suite_duration' in current and 'test_suite_duration' in baseline:
        current_time = current['test_suite_duration']
        baseline_time = baseline['test_suite_duration']
        diff_pct = ((current_time - baseline_time) / baseline_time) * 100

        if abs(diff_pct) > 5:
            entry = f"Test suite duration: {diff_pct:+.1f}% ({current_time:.2f}s vs {baseline_time:.2f}s)"
            if diff_pct < 0:
                comparison['improvements'].append(entry)
            else:
                comparison['regressions'].append(entry)

    # Compare hello world compile time
    if 'hello_world' in current and 'hello_world' in baseline:
        hw_current = current['hello_world']
        hw_baseline = baseline['hello_world']

        if 'compile_time_seconds' in hw_current and 'compile_time_seconds' in hw_baseline:
            curr_time = hw_current['compile_time_seconds']
            base_time = hw_baseline['compile_time_seconds']
            diff_pct = ((curr_time - base_time) / base_time) * 100 if base_time > 0 else 0

            if abs(diff_pct) > 10:
                entry = f"Hello world compile time: {diff_pct:+.1f}% ({curr_time:.3f}s vs {base_time:.3f}s)"
                if diff_pct < 0:
                    comparison['improvements'].append(entry)
                else:
                    comparison['regressions'].append(entry)

    if comparison['regressions']:
        comparison['status'] = 'regression'
    elif comparison['improvements']:
        comparison['status'] = 'improvement'
    else:
        comparison['status'] = 'neutral'

    return comparison

def generate_comparison_summary(comparison, output_file):
    summary = ["# 📈 Performance Comparison Results\n"]

    status_emoji = {
        'improvement': '🚀',
        'regression': '⚠️',
        'neutral': '➖',
        'unknown': '❓'
    }

    summary.append(f"**Overall Status:** {status_emoji[comparison['status']]} {comparison['status'].title()}\n")

    if comparison['improvements']:
        summary.append("## ✅ Performance Improvements")
        for imp in comparison['improvements']:
            summary.append(f"- {imp}")
        summary.append("")

    if comparison['regressions']:
        summary.append("## ⚠️ Performance Regressions")
        for reg in comparison['regressions']:
            summary.append(f"- {reg}")
        summary.append("")

    if not comparison['improvements'] and not comparison['regressions']:
        summary.append("No significant performance changes detected.\n")

    with open(output_file, 'w') as f:
        f.write('\n'.join(summary))

def main():
    if os.environ.get('GITHUB_EVENT_NAME') != 'pull_request':
        print("Comparison only runs on pull requests")
        return 0

    script_dir = Path(__file__).parent
    project_root = script_dir.parent.parent
    results_file = project_root / "perf-results" / "results.json"

    with open(results_file, 'r') as f:
        current_results = json.load(f)

    try:
        baseline_results = get_baseline_results()
    except Exception as e:
        print(f"Could not get baseline results: {e}")
        return 1

    comparison = compare_results(current_results, baseline_results)

    comparison_file = project_root / "perf-results" / "comparison.md"
    generate_comparison_summary(comparison, comparison_file)

    summary_file = project_root / "perf-results" / "summary.md"
    if comparison_file.exists():
        with open(summary_file, 'a') as main_summary, open(comparison_file, 'r') as comp_summary:
            main_summary.write('\n\n---\n\n')
            main_summary.write(comp_summary.read())

    print("Comparison completed successfully!")
    return 0

if __name__ == "__main__":
    sys.exit(main())
