#!/usr/bin/env bash
set -euo pipefail

BIN=./verify-lib
PASS=0
FAIL=0

expect_ok() {
    local desc="$1"; shift
    if "$BIN" "$@" >/dev/null 2>&1; then
        ((PASS++))
    else
        echo "FAIL (expected ok): $desc"
        ((FAIL++))
    fi
}

expect_fail() {
    local desc="$1"; shift
    if "$BIN" "$@" >/dev/null 2>&1; then
        echo "FAIL (expected fail): $desc"
        ((FAIL++))
    else
        ((PASS++))
    fi
}

PREFIX=$(mktemp -d)
LIB="${PREFIX}/lib"
trap 'rm -rf "$PREFIX"' EXIT

mkdir -p "$LIB"

# ── Tests that work without root ────────────────────────

# symlink escape
echo '# valid' > "${LIB}/good.sh"
chmod 644 "${LIB}/good.sh"

ln -sf /etc/hostname "${LIB}/escape.sh"
expect_fail "symlink escape" "${LIB}/escape.sh" "${LIB}/"

# nonexistent file
expect_fail "nonexistent" "${LIB}/nonexistent.sh" "${LIB}/"

# wrong prefix
expect_fail "wrong prefix" "${LIB}/good.sh" "/somewhere/else/"

# not a regular file (directory)
mkdir -p "${LIB}/subdir"
expect_fail "directory" "${LIB}/subdir" "${LIB}/"

# default prefix rejects our temp path
expect_fail "default prefix rejects" "${LIB}/good.sh"

# ── Tests that require root ─────────────────────────────

if [[ $EUID -eq 0 ]]; then
    # valid file: root-owned, no group/other write
    chown root:root "$LIB" "${LIB}/good.sh"
    expect_ok "valid file" "${LIB}/good.sh" "${LIB}/"

    # output is resolved path
    out=$("$BIN" "${LIB}/good.sh" "${LIB}/")
    real=$(realpath "${LIB}/good.sh")
    if [[ "$out" == "$real" ]]; then
        ((PASS++))
    else
        echo "FAIL: output '$out' != expected '$real'"
        ((FAIL++))
    fi

    # group-writable
    cp "${LIB}/good.sh" "${LIB}/gwrite.sh"
    chown root:root "${LIB}/gwrite.sh"
    chmod 664 "${LIB}/gwrite.sh"
    expect_fail "group-writable" "${LIB}/gwrite.sh" "${LIB}/"

    # world-writable
    cp "${LIB}/good.sh" "${LIB}/wwrite.sh"
    chown root:root "${LIB}/wwrite.sh"
    chmod 646 "${LIB}/wwrite.sh"
    expect_fail "world-writable" "${LIB}/wwrite.sh" "${LIB}/"

    # non-root owner
    if id nobody &>/dev/null; then
        cp "${LIB}/good.sh" "${LIB}/badowner.sh"
        chown nobody:root "${LIB}/badowner.sh"
        chmod 644 "${LIB}/badowner.sh"
        expect_fail "non-root owner" "${LIB}/badowner.sh" "${LIB}/"
    fi

    # non-root group
    if getent group nobody &>/dev/null; then
        cp "${LIB}/good.sh" "${LIB}/badgroup.sh"
        chown root:nobody "${LIB}/badgroup.sh"
        chmod 644 "${LIB}/badgroup.sh"
        expect_fail "non-root group" "${LIB}/badgroup.sh" "${LIB}/"
    fi
else
    echo "SKIP: ownership tests (not root)"

    # without root, ALL files fail verify-lib because uid != 0
    # verify that our file is correctly rejected
    expect_fail "non-root owned file" "${LIB}/good.sh" "${LIB}/"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
