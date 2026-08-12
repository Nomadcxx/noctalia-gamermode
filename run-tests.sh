#!/bin/sh
# Run the whole suite from the repository root.
set -eu

cd "$(dirname "$0")"

status=0

for test in tests/*.lua; do
    # helpers.lua is the shared harness, not a test.
    [ "$test" = "tests/helpers.lua" ] && continue
    lua "$test" || status=1
done

for test in tests/*.sh; do
    sh "$test" || status=1
done

# Plugin sources must at least parse.
for source in gamer-mode/*.luau animoo-noctalia/*.luau; do
    lua -e "assert(loadfile('$source'))" || status=1
done

if [ "$status" -ne 0 ]; then
    echo "FAILED" >&2
    exit 1
fi

echo "all tests passed"
