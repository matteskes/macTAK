#!/usr/bin/env python3
"""Summarize a `ninja -k 0` log: which sources failed, and the first error each.

usage: summarize-build.py BUILD_LOG ENGINE_DIR
       ENGINE_DIR  the engine copy the build compiled; its prefix is cut
                   from paths so the summary reads cpp/..., jni/...
prints: counts, one line per failed target with its first error, then the
        error messages grouped by kind (paths and names stripped) so one
        root cause that breaks many sources shows up once, then every
        undefined symbol a failed link reported, with the first object
        that references it
"""
import collections
import re
import sys

FAILED = re.compile(r"^FAILED: (?:\[code=\d+\] )?(\S+)")
ERROR = re.compile(r"^(.*?):(\d+):\d+: (?:fatal )?error: (.*)$")
LINK_ERROR = re.compile(r"^(ld: .*|Undefined symbols.*|clang: error: .*)$")
PROGRESS = re.compile(r"^\[(\d+)/(\d+)\]")
UNDEFINED = re.compile(r'^  "(.+)", referenced from:$')
REFERENCED_BY = re.compile(r"^      (.+?) in (\S+)$")


def kind(message):
    """An error message with its specifics blanked, for grouping."""
    message = re.sub(r"'[^']*'", "'…'", message)
    return re.sub(r"\d+", "N", message)


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    log_path, engine_dir = argv
    prefix = engine_dir.rstrip("/") + "/"

    failures = []            # [target, first error or None]
    kinds = collections.Counter()
    undefined = {}           # symbol -> first referencing object
    pending_symbol = None
    total = 0
    with open(log_path, errors="replace") as log:
        for line in log:
            line = line.rstrip("\n")
            symbol = UNDEFINED.match(line)
            if symbol:
                pending_symbol = symbol.group(1)
                undefined.setdefault(pending_symbol, "?")
                continue
            if pending_symbol:
                ref = REFERENCED_BY.match(line)
                if ref and undefined[pending_symbol] == "?":
                    undefined[pending_symbol] = ref.group(2)
                pending_symbol = None
            progress = PROGRESS.match(line)
            if progress:
                total = int(progress.group(2))
            failed = FAILED.match(line)
            if failed:
                failures.append([failed.group(1), None])
                continue
            error = ERROR.match(line) or LINK_ERROR.match(line)
            if not error:
                continue
            if error.re is ERROR:
                text = (f"{error.group(1).replace(prefix, '')}:{error.group(2)}: "
                        f"{error.group(3)}")
                kinds[kind(error.group(3))] += 1
            else:
                text = error.group(1)
                kinds[kind(text)] += 1
            if failures and failures[-1][1] is None:
                failures[-1][1] = text

    print(f"[g1] build steps: {total}, failed: {len(failures)}")
    for target, first in failures:
        name = re.sub(r"^.*?CMakeFiles/[^/]+\.dir/", "", target)
        name = name.replace(prefix, "")
        print(f"  FAILED {name}")
        print(f"         {first or '(no error line found; see build.log)'}")
    if kinds:
        print("[g1] errors by kind (count, message with names blanked):")
        for message, count in kinds.most_common(40):
            print(f"  {count:4}  {message}")
    if undefined:
        print(f"[g1] undefined symbols at link: {len(undefined)}")
        for symbol, obj in sorted(undefined.items()):
            obj = re.sub(r"^.*?CMakeFiles/[^/]+\.dir/", "", obj)
            print(f"  {symbol}  <- {obj}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
