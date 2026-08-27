#!/bin/bash
# Dependency-free assertions for the bash tests. Each test_*.sh sources this,
# asserts, and calls `finish`.

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HELPERS_DIR/../../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
export REPO_ROOT SCRIPTS_DIR

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() { # desc, expected, actual
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$2" == "$3" ]]; then
        echo "  ✓ $1"
    else
        echo "  ✗ $1"
        echo "      expected: [$2]"
        echo "      actual:   [$3]"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_eq() { # desc, unwanted, actual
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$2" != "$3" ]]; then
        echo "  ✓ $1"
    else
        echo "  ✗ $1"
        echo "      must not be: [$2]"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() { # desc, haystack, needle
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$2" == *"$3"* ]]; then
        echo "  ✓ $1"
    else
        echo "  ✗ $1"
        echo "      '$3' not found in output"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() { # desc, haystack, needle
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$2" != *"$3"* ]]; then
        echo "  ✓ $1"
    else
        echo "  ✗ $1"
        echo "      '$3' unexpectedly found in output"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Fresh directory of mock executables, prepended to PATH. Sets MOCK_BIN.
setup_mock_bin() {
    MOCK_BIN="$(mktemp -d)"
    export MOCK_BIN
    export PATH="$MOCK_BIN:$PATH"
}

# write_mock <name>; body is read from stdin.
write_mock() {
    cat > "$MOCK_BIN/$1"
    chmod +x "$MOCK_BIN/$1"
}

finish() {
    echo "  ── $((TESTS_RUN - TESTS_FAILED))/$TESTS_RUN passed"
    [[ "$TESTS_FAILED" -eq 0 ]]
}
