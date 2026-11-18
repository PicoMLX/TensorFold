#!/bin/sh
# Stamp the native library from the checkout used for this build.
set -eu

output=$1
: > "$output"
prefix=$(git rev-parse --show-prefix 2>/dev/null) || exit 0
[ -z "$prefix" ] || exit 0
revision=$(git rev-parse --verify HEAD 2>/dev/null) || exit 0

{
    printf '{"revision":"%s"' "$revision"
    if tag=$(git describe --tags --exact-match HEAD 2>/dev/null); then
        # Git ref names exclude backslashes and ASCII control characters.
        escaped_tag=$(printf '%s' "$tag" | sed 's/"/\\"/g')
        printf ',"tag":"%s"' "$escaped_tag"
    fi
    if status=$(git --no-optional-locks status --porcelain --ignore-submodules=none 2>/dev/null); then
        if [ -n "$status" ]; then
            printf ',"dirty":true'
        else
            printf ',"dirty":false'
        fi
    fi
    printf '}\n'
} > "$output"
