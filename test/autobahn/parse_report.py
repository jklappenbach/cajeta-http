#!/usr/bin/env python3
"""Turn an Autobahn fuzzingclient report (reports/index.json) into a
pass/fail summary and a process exit code.

A case passes when both its `behavior` and `behaviorClose` are one of
OK / NON-STRICT / INFORMATIONAL / UNIMPLEMENTED (the plan allows
"non-strict"; UNIMPLEMENTED marks a case the suite itself skipped). FAILED
or WRONG CODE is a real failure. Exit 0 iff no case failed.
"""
import json
import sys
from pathlib import Path

OK_BEHAVIORS = {"OK", "NON-STRICT", "INFORMATIONAL", "UNIMPLEMENTED"}


def natural(case_id):
    return [int(p) if p.isdigit() else p for p in case_id.split(".")]


def main():
    report = Path(sys.argv[1] if len(sys.argv) > 1 else "reports/index.json")
    if not report.exists():
        print(f"FAIL: report not found at {report}", file=sys.stderr)
        return 2
    data = json.loads(report.read_text())

    total = passed = failed = 0
    failures = []
    for agent, cases in data.items():
        for case_id, info in sorted(cases.items(), key=lambda kv: natural(kv[0])):
            total += 1
            behavior = info.get("behavior", "MISSING")
            behavior_close = info.get("behaviorClose", "MISSING")
            ok = behavior in OK_BEHAVIORS and behavior_close in OK_BEHAVIORS
            if ok:
                passed += 1
            else:
                failed += 1
                failures.append((agent, case_id, behavior, behavior_close))

    print(f"Autobahn fuzzingclient: {passed}/{total} cases passed, {failed} failed")
    if failures:
        print("\nFailures:")
        for agent, case_id, behavior, behavior_close in failures:
            print(f"  {agent} case {case_id}: behavior={behavior} close={behavior_close}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
