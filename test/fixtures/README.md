<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul integration test fixtures

> ⚠️ **READ THIS BEFORE TOUCHING ANYTHING IN THIS DIRECTORY.**
>
> All cryptographic material in this directory is **publicly known
> throwaway test data**, intentionally committed to a public
> repository.  Anyone who can read the repo can decrypt and use it.
>
> It exists for one purpose: to exercise Sigul's `import-key` code
> path in the integration test suite without having to generate a
> fresh 4096-bit RSA key on every test run (which is slow inside
> a container with limited entropy).
>
> **The key, both passphrases, and the encoding scheme are public.
> Do not, under any circumstances, use any of this material to sign
> anything that matters.**

## Files

- `regenerate-import-test-key.sh` — developer-time helper that
  regenerates the fixture key.  Not run in CI.
- `sigul-import-test-key.b64` — the throwaway 4096-bit RSA secret
  key, GPG-symmetric-encrypted then base64-encoded.  Public.
- `sigul-import-test.passphrase` — the passphrase for the outer
  GPG-symmetric envelope.  Public.
- `sigul-import-test-key.passphrase` — the passphrase the actual
  key is itself protected with.  Public.
- `sigul-import-test-key.fingerprint` — the 40-character SHA-1
  fingerprint of the key, for verification after import.  Public.

## Why is the key encoded twice?

Two reasons, both about CI hygiene rather than security:

1. **GitHub secret scanning**.  The string
   `-----BEGIN PGP PRIVATE KEY BLOCK-----` is on GitHub's secret
   scanner denylist.  Committing a raw armored secret key would
   produce a security alert on every commit and force a maintainer
   to dismiss it manually each time.

2. **Defence in depth against accidental misuse**.  An automated
   tool that grabs every `*.asc` file in a public repo and tries
   `gpg --import` will not do anything useful with the encoded
   blob: it has to be base64-decoded *and* GPG-decrypted with the
   right passphrase first.  The decoded key still has its UID
   stamped with `PUBLICLY-KNOWN-THROWAWAY-DO-NOT-USE-IN-PRODUCTION`,
   so anyone naïvely importing it will see the warning every time
   they list their secret keys.

## How to decode the key (test-time recipe)

```sh
base64 -d test/fixtures/sigul-import-test-key.b64 \
  | gpg --batch --pinentry-mode loopback \
        --passphrase-file test/fixtures/sigul-import-test.passphrase \
        --decrypt \
  > /tmp/import-key.asc
# /tmp/import-key.asc is now an armored secret key, GPG-protected
# with the passphrase in sigul-import-test-key.passphrase
```

CI integration tests do this automatically before invoking
`sigul import-key`.

## How to regenerate the fixture (5-year rotation, key compromise, etc.)

```sh
test/fixtures/regenerate-import-test-key.sh
```

The script:

1. Generates a fresh 4096-bit RSA key in a throwaway `GNUPGHOME`.
2. Sets the UID to `Sigul Integration Test
   (PUBLICLY-KNOWN-THROWAWAY-DO-NOT-USE-IN-PRODUCTION)`.
3. Sets a 5-year expiry so misused copies later self-disable.
4. Wraps it with `gpg --symmetric AES256` using the public outer
   passphrase, then base64-encodes the result.
5. Performs a round-trip self-check: decodes, re-imports, confirms
   the key survives the round-trip.
6. Overwrites the four fixture files in this directory.

After running, commit all four files in a single PR with a clear
message explaining the rotation reason.
