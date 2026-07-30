#!/bin/sh
# Luau's sandbox gives plugins no `io` library, no `os.execute`/`os.remove`/`os.rename`
# and no `load`/`loadstring`/`require`. Reaching for any of them compiles fine under the
# plain `lua` used by the tests and then fails at runtime inside the shell, so guard the
# plugin sources here. Test files are exempt: they run under real Lua on purpose.
set -eu

status=0

for source in gamermode/*.luau; do
    matches=$(grep -nE '(^|[^[:alnum:]_.])(io\.[a-zA-Z]+|os\.(execute|remove|rename|tmpname|exit|getenv)|load|loadstring|dofile|require)[[:space:]]*\(' "$source" || true)
    if [ -n "$matches" ]; then
        echo "$source reaches for an API the Luau sandbox does not provide:" >&2
        echo "$matches" >&2
        status=1
    fi
done

# The same mistake in reverse: filesystem work must go through the noctalia bindings.
grep -q 'noctalia.readFile' gamermode/service.luau || {
    echo "service.luau should read files through noctalia.readFile" >&2
    status=1
}
grep -q 'noctalia.writeFile' gamermode/service.luau || {
    echo "service.luau should write files through noctalia.writeFile" >&2
    status=1
}

[ "$status" -eq 0 ] || exit 1

echo "sandbox: passed"
