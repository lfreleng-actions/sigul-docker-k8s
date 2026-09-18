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
**Upstream Status:** Local fork (upstream Sigul is unmaintained; see below)
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
**Upstream Status:** Local fork (upstream Sigul is unmaintained; see below)
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
**Upstream Status:** Local fork (upstream Sigul is unmaintained; see below)
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
**Upstream Status:** Local fork (upstream Sigul is unmaintained; see below)
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
**Upstream Status:** Local fork (upstream Sigul is unmaintained; see below)
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

### 06-fix-double-tls-teardown-deadlock.patch

**Status:** CRITICAL - without it the server stops serving after a
connection is torn down, while still appearing healthy
**Upstream Status:** Local fork (upstream Sigul is unmaintained; see below)
**Affects:** Server (and any `DoubleTLSClient` user)

**Problem:**
Teardown of a double-TLS connection waits on the peer without any
bound, in two places:

- `_ForwardingBuffer.forward_two_way()` polls with
  `PR_INTERVAL_NO_TIMEOUT`, and `_SplittingBuffer._active` stays true
  until the peer's socket reports EOF.
- `DoubleTLSClient.outer_close()` then calls `os.waitpid(pid, 0)` on
  the forwarding child, also unbounded.

A peer that receives our `FIN` but never sends its own therefore pins
three processes: the forwarding child in `poll()`, the connection owner
in `waitpid()`, and the daemon's main loop in `waitpid()` on that. The
main loop never forks a replacement child, so nothing reconnects to the
bridge and every later request fails with `Unexpected EOF in NSPR`.

Observed in production: the server sat in exactly this state for six
hours after serving one request. The socket to the bridge was in
`FIN-WAIT-2`, the bridge held the other half in `CLOSE-WAIT`, and
`/proc/*/wchan` showed `do_wait`, `do_wait`, `poll_schedule_timeout`.
The process was still present, so a process-existence liveness check
kept passing throughout.

Upstream's own backstop does not cover this. The
`signal.alarm(CHILD_TIMEOUT_SECS)` set in `server.py` is what starts
the teardown in the first place (see the trigger note below), and once
the child is blocked in `waitpid()` nothing else fires: `SigPnd: 0`
after six hours simply means the one-shot alarm had already been
delivered and consumed.

**Fix:**
Bound both waits, and only during teardown of the forwarding child:

- `forward_two_way()` gains an optional `shutdown_linger`. Only
  `DoubleTLSClient.__child()` passes it: there `buf_1` going inactive
  means the pipes are gone and our shutdown has been forwarded, so the
  loop switches to a one-second poll tick and gives the peer
  `_SHUTDOWN_LINGER_SECONDS` (five) to close before abandoning the
  connection. While the local side is still open it blocks
  indefinitely as before, so an idle daemon still waits hours for the
  next request. The linger is short because nothing of value can
  arrive once the local side is gone; it exists so a healthy close
  stays clean.
- The bridge's `bridge_inner_stream()` shares the primitive but does
  not pass a linger. There `buf_1` inactive means only that the client
  has finished its half of the inner session while the server's half
  is still in flight; a linger applied there would abandon live
  requests.
- `outer_close()` reaps through `WNOHANG` up to
  `_CHILD_EXIT_TIMEOUT_SECONDS` (ten), then `SIGKILL`s the forwarding
  child. This bound exceeds the linger plus a tick on purpose: the
  child's own linger is the graceful path, and the kill is the
  fallback for a child stuck somewhere other than the poll loop. The
  child holds no state worth preserving either way.

Preserving the unbounded idle case is the constraint that shapes this
patch: a blanket timeout would be a worse bug than the one it fixes.

**Test:** `test/test_double_tls_teardown.py`, which drives the real
code with a peer that never closes. Against unpatched sigul the first
check reports `STILL BLOCKED`; against patched it returns at the linger
bound, while the idle check confirms indefinite waiting still works
and a bridge-shaped call without a linger keeps waiting too. A further
check forks a real forwarding child and closes it through the real
`outer_close()`, asserting the child exits on its own before the kill
fires; a source check pins that `__child()` is the one caller passing
the linger.

`scripts/run-lifecycle-tests.sh` phase 4 then reproduces the
production deadlock on the live stack: it freezes the bridge so it
cannot close, and fires the server child's hourly alarm early. Against
v2.2.4 the child is still wedged in `waitpid()` thirty seconds later
and the next request fails with `Unexpected EOF in NSPR`; against the
patched images it abandons the connection within the linger, a
replacement connects, and the next request succeeds.

**Trigger, for the record:** `server.py` arms `signal.alarm(3600)` in
every forked child at fork time, whether or not a request ever
arrives. An idle child therefore tears its connection down after an
hour. With an unpatched bridge that teardown is never answered (see
07), and with an unpatched server it never completes. Production
served one request and then wedged while idle, which this explains
without any network fault.

### 07-fix-bridge-server-socket-lifecycle.patch

**Status:** CRITICAL - without it the bridge leaks a socket per failed
server handshake and hands dead server connections to clients
**Upstream Status:** Local fork (upstream Sigul is unmaintained; see below)
**Affects:** Bridge

**Problem:**
`bridge_one_request()` accepts one server connection, then blocks in a
bare `client_listen_sock.accept()` until a client arrives. Two defects
follow from that shape:

- The server socket is closed only inside the client-wait block. A
  server that fails its outer TLS handshake, or presents no
  certificate, is accepted, rejected and then never closed. Each such
  attempt leaks one socket, left in `CLOSE-WAIT` with the peer's final
  bytes unread, for the life of the bridge process. Anything that can
  reach the server port - a scanner, a misconfigured peer, a
  crash-looping server - can grow this without bound.
- While waiting for a client the bridge has no knowledge of the server
  socket. A server that dies during that wait, which in production can
  last hours, is only discovered when a client finally connects and is
  paired with the corpse; that client fails with `Unexpected EOF`. The
  server's `FIN` also sits unread, so the bridge never closes its half.
  This is the other side of patch 06: an unpatched server's teardown
  waits forever on exactly that missing close.

Observed in production: the bridge held three `CLOSE-WAIT` sockets on
the server port, one with 98 unread bytes, alongside
`Unexpected EOF on outer stream` and `_InnerBridgingBuffer: data
dropped` in its log, while the server sat in the patch 06 deadlock.

**Fix:**

- Replace the bare `accept()` with `_wait_for_client_or_server_loss()`,
  an NSPR poll on both `client_listen_sock` and `server_sock`. A server
  that has completed its handshake sends nothing until a client
  arrives, so any readiness on its socket means it has closed or
  failed. The bridge logs, discards it and returns to waiting for a
  fresh server instead of pairing the next client with a dead one.
- Close both sockets in a `finally` that covers every exit path of
  `bridge_one_request()`, including the handshake and certificate
  failures the old structure skipped.

The poll stays unbounded: the bridge must still wait indefinitely for
the next client, exactly as before. Only what it notices while waiting
changes.

**Test:** `scripts/run-lifecycle-tests.sh`, run against the compose
stack after the signing tests. It asserts on socket and process
tables, not log text: five bogus TLS handshakes on the server port
must leave no new `CLOSE-WAIT` sockets, and a server restart while the
bridge waits for a client must leave none either, with the first
request after the restart succeeding. Against unpatched sigul the
handshake phase leaks one socket per attempt.

### 08-fix-server-reap-orphaned-children.patch

**Status:** CRITICAL - without it the server accumulates one zombie
process per gpg helper it spawns, until the container's pid limit
stops it forking at all
**Upstream Status:** Local fork (upstream Sigul is unmaintained; see below)
**Affects:** Server

**Problem:**
The server's main loop forks one child per connection and waits for
it with `os.waitpid(child_pid, 0)` - that child, and only that child.
In a container the server is PID 1, so every process orphaned anywhere
beneath it is reparented to it, and nothing else will ever wait for
those. The gpg helpers spawned while signing are orphaned that way by
design: gpgme double-forks so that it need not wait for them. Each one
therefore stays a zombie for the life of the daemon.

Measured by the soak harness: roughly ten zombies per signing request
(`gpg`, `gpgconf`, and a `python3` per request), 7,423 after
twenty-eight minutes of load. The local Kubernetes pod reports
`pids.max` of 11,965; at that point `fork()` fails and the server
stops serving until the pod is restarted. Each zombie also holds
around 7 KB of kernel memory, which shows as steady RSS growth.
Control-plane requests (`list-users`, `list-keys`) do not spawn gpg
and leave nothing behind.

**Fix:**
Replace the targeted wait with a loop over `os.waitpid(-1, 0)` that
reaps whatever exits until the request child itself is returned. The
main loop is blocked in that wait for the whole life of each child,
so orphans are reaped as they die rather than accumulating. Only the
request child's status is inspected; the others are logged at debug
level.

This only helps when the server is PID 1. Under the Helm chart it is.
Under Compose `scripts/entrypoint-server.sh` used `su`, which stayed
resident as the daemon's parent and reaped nothing; it now drops
privileges with `setpriv` so the daemon is PID 1 there too, matching
the chart. The environment is passed through as `su` passed it, with
`HOME`, `USER`, `LOGNAME` and `SHELL` set from the passwd entry.

**Test:** the soak harness's `sigul-server: no zombie processes` and
`RSS trend` invariants, previously marked expected-fail against
issue #14.

### 09-fix-bridge-handshake-deadline.patch

**Status:** CRITICAL - without it one silent connection stops all
signing for as long as it stays open
**Upstream Status:** Local fork (upstream Sigul is unmaintained; see below)
**Affects:** Bridge

**Problem:**
The bridge accepts a peer and calls `force_handshake()` on it with no
deadline. It serves one client at a time, so a peer that connects and
then sends nothing holds the only slot there is until it goes away: a
port scanner, a load balancer or health check that opens a bare TCP
connection, a client suspended between `connect()` and its
ClientHello, or a NAT that drops the client's packets after the SYN.
The same applies on the server port while the bridge waits for a
server. NSPR sockets do not honour `socket.setdefaulttimeout()`, so
the daemon's one-hour default gave no protection either.

Measured by the soak harness: two silent connections to the client
port, **0 requests served in 60 s**; service resumed only when they
closed.

**Fix:**
Both handshakes go through `_handshake_with_deadline()`, a wall-clock
bound of five seconds on the whole handshake. NSS's own
`force_handshake_timeout()` is not enough: it limits each individual
read, so a peer trickling one byte a second passes it indefinitely -
measured, an honest request behind such a peer was still waiting at
sixty seconds. Instead the socket is switched to non-blocking, the
handshake is driven a step at a time, and between steps the socket is
polled with the remaining time; blocking mode is restored on every
path. A real Sigul peer completes the handshake in well under a second
even across a WAN, and the clock starts at `accept()`, so time queued
in the listen backlog does not count. On expiry the bridge raises
`PR_IO_TIMEOUT_ERROR`, logs a plain `Peer stopped responding ...;
dropping it` warning naming both this deadline and patch 11's, and,
through the patch 07 cleanup, closes the
peer and returns to its accept loop. When
the dropped peer was a client, the paired server connection is closed
with it and the server reconnects within a second, as for any other
rejected client.

**Test:** with two silent connections parked on the client port, an
honest `list-users` is now served after nine seconds (two deadlines)
rather than never; behind a one-byte-a-second slow-loris it is served
after two; a silent connection parked on the server port delays a
restarted server's pairing by one deadline rather than forever. The
soak harness's `client_connect_and_hang` fault, previously marked
expected-fail against issue #11, passes.

### 10-fix-bridge-listen-backlog.patch

**Status:** IMPORTANT - without it a burst of concurrent clients is
partly refused, and the `sigul` CLI does not retry
**Upstream Status:** Local fork (upstream Sigul is unmaintained; see below)
**Affects:** Bridge

**Problem:**
`create_listen_sock()` calls `listen()` with the python-nss default
backlog of five. The bridge accepts one connection at a time, and
only between requests, so everything that arrives while it is busy
waits in that queue. Six CI jobs signing together overflow it: the
kernel drops the excess SYNs, the clients' kernels retry with
exponential backoff, and after a few retries `connect()` fails
outright with nothing to tell the client it was merely early.

Measured: twelve concurrent `list-users` clients against the default
produced seven `TcpExtListenDrops`; the clients survived only because
the kernel's SYN retries happened to fit inside the CLI's timeout.

**Fix:**
`listen(128)` on both listening sockets. Nothing about the workload
changes - the bridge still serves one client at a time - except that
a burst waits its turn instead of being turned away. Twelve and thirty
concurrent clients against the patched bridge: zero drops, all served,
in six and eight seconds respectively.

A large backlog does mean that connections which will never complete
a handshake now queue rather than being dropped; each costs one
handshake deadline (patch 09) when its turn comes. That is the
trade-off the soak harness's `client_backlog_flood` fault measures,
and it remains marked expected-fail against issue #13 until
handshakes are taken off the accept loop's critical path.

### 11-fix-bridge-request-idle-deadline.patch

**Status:** CRITICAL - without it a client that goes silent
mid-request holds the bridge's single slot for as long as it likes
**Upstream Status:** Local fork (upstream Sigul is unmaintained; see below)
**Affects:** Bridge (and `double_tls.OuterBuffer` /
`forward_two_way`, which gain optional deadlines the server and client
do not use)

**Problem:**
Once a client has completed its handshake and the bridge is relaying
its request, every read and write on either peer blocks with no
deadline: `OuterBuffer` for the headers and payloads, `forward_two_way`
for the inner stream. A client suspended mid-upload, a CI runner
paused by its scheduler, or a peer behind a NAT that has dropped the
flow all look exactly like a slow peer. The bridge serves one client
at a time, so everyone else waits until the frozen client is killed -
the soak harness measured a real `sign-data` frozen at 6 MB into a
384 MB upload blocking all signing for the whole window. The server's
one-hour alarm was the only bound.

**Fix:**
`OuterBuffer` takes an optional `idle_timeout`, applied to each receive
and send; `forward_two_way` takes one too and raises
`IdleTimeoutError` when a full period passes with no event on any
descriptor. Only the bridge passes them, at 120 seconds: a peer that
moves no bytes at all for two minutes mid-request has stopped. On
expiry the bridge logs the drop plainly and, through the patch 07
cleanup, closes both peers and returns to its accept loop; the server
reconnects within a second. No legitimate Sigul operation goes two
minutes without a byte crossing the bridge - the largest signing
operations either stream or finish in seconds - and the full signing
suite passes unchanged against the patched bridge.

The server and client code paths are untouched: the defaults keep
their previous unbounded behaviour.

**Test:** a real client frozen 6 MB into an upload; an honest
`list-users` retried every thirty seconds is refused four times and
served at 122 seconds, where before it was never served. The soak
harness's `client_handshake_then_hang` and `client_stop_mid_sign`
faults now recover within the window.

## Applying Patches

The Docker build process automatically applies these patches:

1. `Dockerfile.{client,bridge,server}` copies this directory to `/tmp/patches/`
2. `build-scripts/install-sigul.sh` clones Sigul v1.4 from upstream (Pagure)
3. The script applies all `*.patch` files in alphanumeric order
4. Sigul is then built and installed with the fixes included

## Upstream status

At the time of writing, upstream Sigul on
[`pagure.io/sigul`](https://pagure.io/sigul) is effectively
unmaintained:

- The most recent commit is the v1.4 release tag, dated roughly a
  year ago.
- Open issues and pull requests have been sitting untouched.
- Pagure itself is scheduled to be decommissioned around mid-2026
  (Flock 2026); Fedora-hosted projects are being asked to migrate
  to `forge.fedoraproject.org`.

In practice this means the patches in this directory are a
**permanent local fork**, not a staging area for upstream
submission.  We carry them indefinitely, and any new fix should be
added here rather than waiting on an upstream release.  When
Pagure goes away we will need to re-host the v1.4 source tarball
that `build-scripts/install-sigul.sh` clones; the patch series itself
is self-contained and will continue to apply against any preserved
copy of v1.4.

## Adding a patch

1. **Keep the patch minimal** — one logical change per file; fix the
   bug, do not refactor surrounding code.
2. **Use the `NN-short-description.patch` filename convention** so
   patches apply in a stable order under
   `build-scripts/install-sigul.sh`.
3. **Include an explanatory header in the patch file itself** that
   describes the bug being fixed and why the chosen fix is the
   right shape; the existing patches use a `# SPDX…` block plus a
   prose explanation above the `diff --git` lines.
4. **Add a corresponding entry to this README** under `## Patches`,
   following the `Status / Affects / Problem / Fix / Impact`
   structure.  Mark the entry CRITICAL if the stack will not start
   without it.
5. **Verify the whole series still applies cleanly:** with the
   bundled Sigul v1.4 source available locally,

   ```bash
   cd .build-context/sigul
   for p in ../../patches/*.patch; do
       git apply --check "$p" || { echo "$p failed"; break; }
   done
   ```

   should print no errors.

## Verifying a single patch in isolation

```bash
# Local copy of upstream v1.4 (or any preserved mirror once Pagure
# is decommissioned)
cd /tmp
git clone --depth 1 --branch v1.4 https://pagure.io/sigul.git
cd sigul
patch -p1 < /path/to/sigul-docker/patches/01-fix-double-tls-handshake-timing.patch
echo $?  # Should be 0
```
