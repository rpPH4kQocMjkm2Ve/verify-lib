#!/usr/bin/env bash
# tests/test.sh — Unit tests for verify-lib
# Run from project root: bash tests/test.sh

set -uo pipefail

BIN=./verify-lib
PASS=0; FAIL=0; SKIP=0; TESTS=0

# ── Test helpers ─────────────────────────────────────────────

ok()   { PASS=$((PASS+1)); TESTS=$((TESTS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); TESTS=$((TESTS+1)); echo "  ✗ $1"; }
skip() { SKIP=$((SKIP+1)); TESTS=$((TESTS+1)); echo "  ⊘ $1 (skipped)"; }
section() { echo ""; echo "── $1 ──"; }

expect_ok() {
    local desc="$1"; shift
    if "$BIN" "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

expect_fail() {
    local desc="$1"; shift
    if "$BIN" "$@" >/dev/null 2>&1; then
        fail "$desc (should have been rejected)"
    else
        ok "$desc"
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$desc"
    else
        fail "$desc (expected='$expected', got='$actual')"
    fi
}

summary() {
    echo ""
    echo "════════════════════════════════════"
    if [[ $SKIP -gt 0 ]]; then
        echo " ${0##*/}: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped (${TESTS})"
    else
        echo " ${0##*/}: ${PASS} passed, ${FAIL} failed (${TESTS})"
    fi
    echo "════════════════════════════════════"
    [[ $FAIL -eq 0 ]]
}

# ── Pre-flight ───────────────────────────────────────────────

if [[ ! -x "$BIN" ]]; then
    echo "Error: $BIN not found — compile first: cc -o verify-lib verify-lib.c"
    exit 1
fi

BIN_ABS="$(realpath "$BIN")"
TESTDIR=$(mktemp -d)
LIB="${TESTDIR}/lib"
trap 'rm -rf "$TESTDIR"' EXIT
mkdir -p "$LIB"

echo '# valid' > "${LIB}/good.sh"
chmod 644 "${LIB}/good.sh"


# ── Path validation ──────────────────────────────────────────

section "Path validation"

ln -sf /etc/hostname "${LIB}/escape.sh"
expect_fail "symlink escape rejected"      "${LIB}/escape.sh"   "${LIB}/"
expect_fail "nonexistent file rejected"     "${LIB}/nonexistent" "${LIB}/"
expect_fail "wrong prefix rejected"         "${LIB}/good.sh"     "/somewhere/else/"
mkdir -p "${LIB}/subdir"
expect_fail "directory rejected"            "${LIB}/subdir"      "${LIB}/"
expect_fail "default prefix rejects tmp"    "${LIB}/good.sh"


# ── Ownership & permissions ──────────────────────────────────

section "Ownership & permissions"

if [[ $EUID -eq 0 ]]; then
    chown root:root "$LIB" "${LIB}/good.sh"
    expect_ok "valid root-owned file accepted" "${LIB}/good.sh" "${LIB}/"

    out=$("$BIN" "${LIB}/good.sh" "${LIB}/")
    real=$(realpath "${LIB}/good.sh")
    assert_eq "output is resolved path" "$real" "$out"

    cp "${LIB}/good.sh" "${LIB}/gwrite.sh"
    chown root:root "${LIB}/gwrite.sh"; chmod 664 "${LIB}/gwrite.sh"
    expect_fail "group-writable rejected" "${LIB}/gwrite.sh" "${LIB}/"

    cp "${LIB}/good.sh" "${LIB}/wwrite.sh"
    chown root:root "${LIB}/wwrite.sh"; chmod 646 "${LIB}/wwrite.sh"
    expect_fail "world-writable rejected" "${LIB}/wwrite.sh" "${LIB}/"

    if id nobody &>/dev/null; then
        cp "${LIB}/good.sh" "${LIB}/badowner.sh"
        chown nobody:root "${LIB}/badowner.sh"; chmod 644 "${LIB}/badowner.sh"
        expect_fail "non-root owner rejected" "${LIB}/badowner.sh" "${LIB}/"
    fi

    if getent group nobody &>/dev/null; then
        cp "${LIB}/good.sh" "${LIB}/badgroup.sh"
        chown root:nobody "${LIB}/badgroup.sh"; chmod 644 "${LIB}/badgroup.sh"
        expect_fail "non-root group rejected" "${LIB}/badgroup.sh" "${LIB}/"
    fi

    if getent group nobody &>/dev/null; then
        GWDIR="${LIB}/gwdir"
        mkdir -p "$GWDIR"
        chown root:nobody "$GWDIR"; chmod 775 "$GWDIR"
        cp "${LIB}/good.sh" "${GWDIR}/lib.sh"
        chown root:root "${GWDIR}/lib.sh"; chmod 644 "${GWDIR}/lib.sh"
        expect_fail "group-writable dir (non-root gid) rejected" \
            "${GWDIR}/lib.sh" "${LIB}/"
    fi
else
    echo "  (skipping — not root)"
    expect_fail "non-root owned file rejected" "${LIB}/good.sh" "${LIB}/"
fi


# ── User namespace ───────────────────────────────────────────

section "User namespace"

if unshare --user --map-root-user true 2>/dev/null; then
    USERNS_DIR=$(mktemp -d)
    trap 'rm -rf "$USERNS_DIR" "$TESTDIR"' EXIT

    # Inside a user namespace the process loses CAP_DAC_OVERRIDE
    # in the init namespace, so restricted paths like /home/user
    # (mode 700, uid≠0) become inaccessible.  Copy the binary into
    # TESTDIR (/tmp/…, uid=0) which the namespace process owns.
    BIN_NS="${TESTDIR}/verify-lib"
    cp "$BIN_ABS" "$BIN_NS"
    chmod 755 "$BIN_NS"

    mkdir -p "${USERNS_DIR}/lib"
    echo '# valid' > "${USERNS_DIR}/lib/test.sh"
    chmod 644 "${USERNS_DIR}/lib/test.sh"

    if [[ $EUID -eq 0 ]]; then
        # uid 1000 is outside the namespace mapping (0 0 1) →
        # appears as overflow_uid (65534) inside.
        chown 1000:1000 "${USERNS_DIR}/lib" "${USERNS_DIR}/lib/test.sh"
    fi

    # ── ro-mount helper (written to file to avoid quoting pain) ──
    #
    # "mount -o remount,ro" inside a user ns fails with EPERM if it
    # would implicitly drop locked VFS flags (nosuid, nodev, …)
    # inherited from the parent mount.  We preserve them via findmnt.
    cat > "${TESTDIR}/ro_test.sh" <<'ROTESTSCRIPT'
#!/bin/sh
DIR="$1"; BIN="$2"
mount --bind "$DIR" "$DIR"                             || exit 99
vopts=$(findmnt -rn -o VFS-OPTIONS "$DIR" 2>/dev/null \
        | sed 's/\brw\b/ro/')
if [ -n "$vopts" ]; then
    mount -o "remount,bind,$vopts" "$DIR"              || exit 98
else
    mount -o remount,bind,ro "$DIR"                    || exit 98
fi
# Sanity: verify mount is actually read-only
touch "$DIR/.probe" 2>/dev/null && { rm -f "$DIR/.probe"; exit 97; }
exec "$BIN" "$DIR/test.sh" "$DIR/"
ROTESTSCRIPT

    # ── overflow_uid on ro mount — should accept ──
    _rc=0
    _out=$(unshare --user --map-root-user --mount --propagation private -- \
        sh "${TESTDIR}/ro_test.sh" \
        "${USERNS_DIR}/lib" "$BIN_NS" 2>&1) || _rc=$?

    case $_rc in
        0)  ok   "overflow_uid on ro mount accepted" ;;
        97) skip "overflow_uid on ro mount — remount had no effect" ;;
        98) skip "overflow_uid on ro mount — remount not permitted" ;;
        99) skip "overflow_uid on ro mount — bind mount failed" ;;
        *)  fail "overflow_uid on ro mount accepted (rc=$_rc: $_out)" ;;
    esac

    # ── overflow_uid on rw mount — should reject ──
    if unshare --user --map-root-user --mount --propagation private -- \
        sh -c "
            mount --bind '${USERNS_DIR}/lib' '${USERNS_DIR}/lib' 2>/dev/null
            exec '$BIN_NS' '${USERNS_DIR}/lib/test.sh' '${USERNS_DIR}/lib/'
        " >/dev/null 2>&1; then
        fail "overflow_uid on rw mount rejected"
    else
        ok   "overflow_uid on rw mount rejected"
    fi

    # ── overflow_uid outside user ns — should reject ──
    if [[ $EUID -eq 0 ]]; then
        cp "${LIB}/good.sh" "${LIB}/overflow.sh"
        chown 65534:65534 "${LIB}/overflow.sh"; chmod 644 "${LIB}/overflow.sh"
        expect_fail "overflow_uid outside userns rejected" \
            "${LIB}/overflow.sh" "${LIB}/"
    fi
else
    echo "  (skipping — unshare --user not available)"
fi


# ── Summary ──────────────────────────────────────────────────

summary
