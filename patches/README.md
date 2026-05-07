<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul Patches

This directory contains patches that fix critical issues in upstream Sigul v1.4
to enable proper operation in containerized environments.

## Purpose

These patches are automatically applied during the Docker image build process
to fix issues that prevent Sigul from working in containers. The
patches remain minimal and focused on critical functionality.

## Patches

### 01-fix-double-tls-handshake-timing.patch

**Status:** CRITICAL - Required for functionality
**Upstream Status:** Not yet submitted
**Affects:** Bridge component

**Problem:**
The upstream Sigul bridge accepts the server's TCP connection but delays the
TLS handshake until a client connects. In containerized environments with
variable connection timing, this causes the server-side TLS handshake to
timeout, resulting in `PR_END_OF_FILE_ERROR` / "Unexpected EOF in NSPR" errors.

**Fix:**
Completes the server TLS handshake right after accepting the TCP
connection, before waiting for client connections. This ensures stable
double-TLS communication.

**Impact:**

- Without this patch: All Sigul operations fail with I/O errors
- With this patch: Stable, reliable double-TLS communication

**Code Changes:**

- Adds `server_sock.force_handshake()` right after server accept
- Adds server certificate validation
- Adds error handling for handshake failures

### 02-verbose-auth-logging.patch

**Status:** Optional - controlled by `SIGUL_DEBUG_AUTH` env var
**Upstream Status:** Not yet submitted
**Affects:** Bridge and server

**Problem:**
Upstream Sigul is intentionally tight-lipped about authentication
failures (to avoid timing/oracle leaks).  In a containerised
stack that produces silent end-to-end failures with no
daemon-side trace to root-cause from.

**Fix:**
Adds a small `_adbg()` helper and call sites at every auth
checkpoint on the bridge and server.  The `SIGUL_DEBUG_AUTH`
environment variable controls output; when unset, behaviour is
bit-for-bit identical to upstream.

**Impact:**

- With `SIGUL_DEBUG_AUTH=1`: every auth checkpoint emits a
  human-readable `AUTHDBG/*` log line (peer cert CN, declared
  user, password-field presence, sha512_password lookup result,
  crypt(3) compare result).  Log lines carry metadata - no
  secret values are ever printed.
- With `SIGUL_DEBUG_AUTH` unset (the default): no logging,
  no per-request peer-cert lookup, no extra `crypt(3)` calls.

**Code Changes:**

- `bridge.py`: log server/client TCP accepts and post-handshake
  peer cert CN.
- `server.py`: log handler dispatch, request fields, and the
  per-step result of `authenticate_admin`'s password compare.
- Renames a shadowed local variable (`user` -> `user_row`) in
  `authenticate_admin` so the log lines are unambiguous.

### 03-fix-delete-key-gpg-home-cleanup.patch

**Status:** CRITICAL - Required for `sigul delete-key` /
`sigul import-key` round-trip to work.
**Upstream Status:** Not yet submitted
**Affects:** Server

**Problem:**
`server_gpg.Context.delete()` uses the legacy
`op_delete(key, allow_secret_bool)` API.  In `python-gpg >= 1.23`
that call is a silent no-op: gpgme deprecated `gpgme_op_delete`,
the python wrapper does not raise, and the secret/public key
material stays in the gnupg-home.

Result: `sigul delete-key` removes the row from the server's
sqlite DB (so `sigul list-keys` no longer reports the key) but
leaves the underlying GPG key material in place.  A follow-up
`sigul import-key` for the same fingerprint fails with
`Error: Invalid import file: Unexpected import file contents`
because gpg reports the key as already-imported.

**Fix:**
Switch to `op_delete_ext(key, mode_flags)` with
`DELETE_ALLOW_SECRET | DELETE_FORCE` flags, the modern API that
actually deletes.

**Impact:**

- Without this patch: `delete-key` is a half-fix that breaks
  every later `import-key` for the same fingerprint, and
  `scripts/run-signing-tests.sh` requires a Phase 0 reset that
  `rm -rf`'s the server gnupg-home before each run.
- With this patch: `delete-key` removes the GPG material as
  expected.  The Phase 0 reset becomes a no-op on a clean stack;
  a follow-up commit can remove it entirely.

### 04-fix-optional-fedora-client-guard.patch

**Status:** CRITICAL on Fedora 44+ - bridge will not start without it
**Upstream Status:** Not yet submitted
**Affects:** Bridge

**Problem:**
`bridge.py` imports `fedora.client` (provided by the
`python3-fedora` package, used only for FAS authentication)
behind a `try/except ImportError` and sets `have_fas` accordingly.
Later, however, the privilege-drop block accesses
`fedora.client.baseclient.SESSION_DIR` *unconditionally*.
When the package is absent the unconditional access raises
`NameError: name 'fedora' is not defined`, the surrounding
exception handler logs a misleading
`Error switching to user 1000: name 'fedora' is not defined`,
and the bridge daemon exits before serving any request.

The `python3-fedora` package was retired between Fedora 41 and
Fedora 44; on F44 base images the bridge therefore fails to
start out-of-the-box.

**Fix:**
Guards the FAS session-dir initialisation with `if have_fas:`,
matching the `try/except` import guard at the top of the module.
When FAS is unavailable the bridge skips the FAS-only setup and
continues normal startup.

**Impact:**

- Without this patch on F44+: bridge crashes at startup; nothing
  works.
- With this patch: bridge runs normally with or without
  `python3-fedora` installed.  We do not use FAS authentication,
  so the only effect is that `python3-fedora` is no longer a
  hard dependency of the bridge image.

### 05-fix-optional-rpm-head-signing.patch

**Status:** CRITICAL on Fedora 44+ - server will not start without it
**Upstream Status:** Not yet submitted
**Affects:** Server

**Problem:**
`server.py` imports `rpm_head_signing` at module top level.
On Fedora 44 the stock `rpm-head-signing-1.7.4-12.fc44` package
was last rebuilt against the older RPM 4.x ABI and references
`rpmWriteSignature`, a symbol that RPM 6.0.1 (the librpm
shipped on Fedora 44) no longer exports.  The C-extension
therefore fails to load with:

```text
ImportError: insertlib.cpython-314-aarch64-linux-gnu.so:
    undefined symbol: rpmWriteSignature
```

Because the import is at module top level, the whole server
crashes on startup before any client request can be handled.

`rpm_head_signing` is used solely by the optional
`sign-rpms --head-signing` code path.  Standard `sign-rpm` and
`sign-rpms` (without `--head-signing`) do not need it.

**Fix:**
Makes the `rpm_head_signing` imports tolerant of
`ImportError`, captures the failure reason, and raises a
helpful `RPMFileError` later, but solely on actual head-signing
requests.  The error message points operators at the
F44 ABI mismatch and tells them to either rebuild
`rpm-head-signing` against the new librpm or use the standard
(non-head-signing) code path.

**Impact:**

- Without this patch on F44+: server crashes at startup;
  nothing works.
- With this patch: server starts cleanly on a stock F44 host;
  all standard signing operations (those that our test suite
  exercises) work.  `--head-signing` remains unavailable on F44
  until the upstream `rpm-head-signing` package gains support
  for the RPM 6 ABI.

## Applying Patches

The Docker build process automatically applies these patches:

1. `Dockerfile.{client,bridge,server}` copies this directory to `/tmp/patches/`
2. `build-scripts/install-sigul.sh` clones Sigul v1.4 from upstream (Pagure)
3. The script applies all `*.patch` files in alphanumeric order
4. Sigul is then built and installed with the fixes included

## Upstream Strategy

Submit these patches to upstream Sigul (<https://pagure.io/sigul>)
to benefit the community and reduce our maintenance burden. Once accepted
upstream, we can remove the patches and use official releases.

**Submission Priority:**

1. **HIGH:** Double-TLS handshake timing fix (this is critical for containers)
2. **HIGH:** Fedora-client / rpm-head-signing optional-import
   guards (patches 04 and 05) - these unbreak Sigul on Fedora
   44+ base images and are not platform-specific to our stack.

## Testing

To verify patches apply cleanly:

```bash
# Test patch application locally
cd /tmp
git clone --depth 1 --branch v1.4 https://pagure.io/sigul.git
cd sigul
patch -p1 < /path/to/sigul-docker/patches/01-fix-double-tls-handshake-timing.patch

# Verify no errors
echo $?  # Should be 0
```

## Contributing

When adding new patches:

1. Keep patches minimal - fix critical issues
2. Use descriptive filenames with numeric prefixes: `01-`, `02-`, etc.
3. Include clear comments explaining WHY the fix matters
4. Test that patches apply cleanly to upstream Sigul v1.4
5. Plan for upstream submission

## Maintenance

When upstream Sigul releases new versions:

1. Test if patches still apply cleanly
2. Update patches if necessary
3. Remove patches that upstream accepts
4. Update `build-scripts/install-sigul.sh` if using newer version
