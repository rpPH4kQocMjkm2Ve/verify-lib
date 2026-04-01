# Tests

## Overview

| File | Language | Framework | What it tests |
|------|----------|-----------|---------------|
| `tests/test.sh` | Bash | Custom assertions | Path validation (symlink escape, nonexistent file, wrong prefix, directory rejection, default prefix), ownership & permissions (root-owned file acceptance, resolved path output, group-writable rejection, world-writable rejection, non-root owner/group rejection, group-writable directory with non-root gid), user namespace handling (overflow_uid on ro mount acceptance, overflow_uid on rw mount rejection, overflow_uid outside userns rejection) |

## Running

```bash
# Build first
make build

# Run as regular user (ownership tests will use non-root path)
bash -x tests/test.sh

# Run as root (full ownership & permission coverage)
sudo bash -x tests/test.sh

# Both (as in CI)
make build && bash -x tests/test.sh && sudo bash -x tests/test.sh
```

## How they work

### Test harness

The test script provides a minimal assertion framework:

- **Assertion functions**: `ok`/`fail`/`skip`/`expect_ok`/`expect_fail`/`assert_eq`
- **Section headers**: `section` for grouping related tests
- **Summary**: final pass/fail/skip counts; exits non-zero if any test failed

### Pre-flight

The script checks that `./verify-lib` is compiled and executable, then creates a temporary directory (`mktemp -d`) with a `lib/` subdirectory containing a valid test file (`good.sh`, mode 644). The temporary directory is cleaned up via `trap EXIT`.

### Path validation

Tests that `verify-lib` correctly rejects:

- **Symlink escape**: a symlink pointing outside the allowed prefix (`/etc/hostname`)
- **Nonexistent file**: a path that does not exist
- **Wrong prefix**: a valid file checked against a prefix it doesn't belong to
- **Directory**: a directory path (only regular files are accepted)
- **Default prefix**: a file under `/tmp` rejected by the default `/usr/lib/` prefix

### Ownership & permissions

Behavior differs based on effective UID:

**As root (`EUID=0`)**:
- Accepts a valid root-owned file (uid=0, gid=0, mode 644)
- Verifies that stdout output matches `realpath` of the input file
- Rejects group-writable files (mode 664)
- Rejects world-writable files (mode 646)
- Rejects files owned by non-root user (`nobody`)
- Rejects files with non-root group (`nobody`)
- Rejects files inside a group-writable directory with non-root gid

**As non-root**: confirms that the file is rejected due to non-root ownership

### User namespace

Requires `unshare --user --map-root-user` support. Tests exercise the user namespace exemption logic in `verify-lib`:

- **overflow_uid on ro mount**: inside a user namespace, files with unmapped uid (overflow_uid=65534) on a read-only bind mount should be **accepted** — real root placed the files, and the read-only mount prevents tampering
- **overflow_uid on rw mount**: same unmapped uid on a writable mount should be **rejected** — the namespace's virtual root could have created those files
- **overflow_uid outside userns**: overflow_uid (65534) outside any user namespace should be **rejected** — it's simply a non-root uid

The ro-mount test uses a helper script (`ro_test.sh`) written to a file to handle the complexity of preserving VFS flags (`nosuid`, `nodev`, etc.) during `mount -o remount,ro` inside a user namespace. The helper returns distinct exit codes (97–99) for mount-related failures, which the test maps to `skip` results rather than failures.

When `unshare --user` is not available (e.g., disabled kernel support), the entire section is skipped.

## CI

The GitHub Actions workflow (`.github/workflows/ci.yml`) runs on push/PR when `verify-lib.c`, `Makefile`, `tests/**`, or the workflow file itself changes:

- **`lint`** job: runs `cppcheck` with `--error-exitcode=1` for warnings, style, and performance checks
- **`test`** job: compiles via `make build`, then runs the test script twice — once as the regular CI user, once as root via `sudo` — to cover both privilege levels

## Test environment

- Bash tests create a temporary directory (`mktemp -d`) cleaned up via `trap EXIT`
- Root privileges required for full coverage (ownership, permission, and user namespace tests); non-root runs exercise the remaining paths with appropriate skips
- No system files are modified; all test artifacts are created in the temporary directory
- User namespace tests require `unshare --user` kernel support; skipped gracefully if unavailable
