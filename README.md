# verify-lib

Validates shell library files before sourcing. Compiled binary — breaks
the bootstrap problem of verifying a shell library from shell.

## Install

### With gitpkg

```sh
gitpkg install verify-lib
```

### AUR
```sh
yay -S verify-lib
```

### Manually

```sh
make build
sudo make install
```

## Usage

```sh
verify-lib /usr/lib/gitpkg/common.sh /usr/lib/gitpkg/
verify-lib /usr/lib/atomic/common.sh /usr/lib/atomic/
verify-lib /usr/lib/foo/bar.sh
```

Returns 0 and prints resolved path on success.
Returns 1 with diagnostics to stderr on failure.

In scripts:

```sh
_src() { local p; p=$(verify-lib "$1" "$2") && source "$p" || exit 1; }
_src /usr/lib/gitpkg/common.sh /usr/lib/gitpkg/
```

Default prefix is `/usr/lib/` when omitted.

## Checks

| Check | Threat |
|-------|--------|
| `realpath` resolution | Symlink escape |
| Path prefix match | Sourcing outside expected directory |
| Regular file test | Device/fifo/socket substitution |
| `0:0` ownership | Unprivileged file replacement |
| No group/other write | Unauthorized modification |
| Directory chain ownership | Parent directory hijack |
| Sticky bit on world-writable dirs | `/tmp`-style race attacks |

## Dependencies

- `gcc`, `make`

## License

AGPL-3.0-or-later
