#!/usr/bin/env python3
"""Static checks for the RouterOS scripts (no RouterOS needed).

Usage: lint_rsc.py FILE [MAX_BYTES]

- A single /tool fetch output=user silently truncates at 64512 bytes. The
  loader (mikrotik-adguardhome.rsc) is fetched that way, so keep it small;
  it downloads adguardhome_script.rsc in ranges, so that file may be larger.
- The whole script must be one { } block, so a truncated download fails
  to parse instead of running partially.
- The completeness marker must appear exactly once, as the last line.
- Brackets, braces, parentheses, and strings must balance.
- Every $variable must be declared (or be a known function argument).
"""
import re
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "adguardhome_script.rsc"
MAX_BYTES = int(sys.argv[2]) if len(sys.argv) > 2 else 60000
MARKER = "#SCRIPT-COMPLETE"
# Function arguments and loop variables used inside helper functions.
ARGS = {
    "containerName", "timeout", "poll", "progress", "command", "value", "path",
    "mode", "src", "dst", "base", "image", "source", "key", "host", "server", "k", "v", "s", "f", "d", "i",
    "n", "c", "m", "p", "id", "sep", "mountId",
}

text = open(PATH, encoding="utf-8").read()
errors = []

size = len(text.encode("utf-8"))
if size > MAX_BYTES:
    errors.append(f"size {size} bytes exceeds {MAX_BYTES}")
if text.count(MARKER) != 1 or text.rstrip().splitlines()[-1] != MARKER:
    errors.append(f"{MARKER} must appear exactly once, as the last line")

# The whole script must be one { } block so a truncated download cannot parse.
code_lines = [l.strip() for l in text.splitlines() if l.strip() and not l.lstrip().startswith("#")]
if not code_lines or code_lines[0] != "{" or code_lines[-1] != "}":
    errors.append("the script must start with '{' and end with '}' (before the marker)")

code, in_string = [], False
for number, line in enumerate(text.splitlines(), 1):
    if line.lstrip().startswith("#") and not in_string:
        continue
    j = 0
    while j < len(line):
        ch = line[j]
        if ch == "\\" and in_string:
            j += 2
            continue
        if ch == '"':
            in_string = not in_string
        elif not in_string:
            code.append(ch)
        j += 1
    if in_string and not line.rstrip().endswith("\\"):
        errors.append(f"line {number}: unterminated string")
        in_string = False
joined = "".join(code)
for pair in ("{}", "[]", "()"):
    if joined.count(pair[0]) != joined.count(pair[1]):
        errors.append(f"unbalanced {pair}: {joined.count(pair[0])} vs {joined.count(pair[1])}")

used = set(re.findall(r"\$([A-Za-z_][A-Za-z0-9_]*)", text))
declared = set(re.findall(r":(?:local|global) ([A-Za-z_][A-Za-z0-9_]*)", text))
undeclared = sorted(used - declared - ARGS)
if undeclared:
    errors.append("undeclared variables: " + ", ".join(undeclared))

if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"OK: {size} bytes")
