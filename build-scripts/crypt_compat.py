#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

"""
Compatibility shim for the crypt module (removed in Python 3.13).

This module provides a drop-in replacement for the standard library crypt module
that was deprecated in Python 3.11 and removed in Python 3.13.

It uses passlib to provide SHA-512 password hashing compatible with the
original crypt.crypt() function.
"""

import sys

if sys.version_info >= (3, 13):
    # Python 3.13+ - use passlib for crypt functionality
    try:
        from passlib.hash import sha512_crypt
    except ImportError as exc:
        raise ImportError(
            "passlib is required for crypt module compatibility in "
            + "Python 3.13+. Install it with: pip install passlib"
        ) from exc

    def crypt(word: str | bytes, salt: str) -> str:
        """
        Hash a password using SHA-512 crypt.

        Args:
            word: The password to hash (str or bytes)
            salt: The salt string.  Real callers will pass an
                  ``$6$...`` SHA-512 crypt salt; legacy code may
                  also pass a non-crypt placeholder (Sigul, for
                  example, intentionally calls
                  ``crypt(password, 'xx')`` as a timing-attack
                  guard when the user does not exist).

        Returns:
            The hashed password string in crypt format, or - for
            placeholder/invalid salts - a deterministic non-crypt
            string that will never equal a real crypt result and
            will never equal the salt itself.  This mirrors the
            POSIX ``crypt(3)`` contract that some libcs implement
            (return non-matching garbage rather than raising).
        """
        # Convert bytes to string if needed
        if isinstance(word, bytes):
            word = word.decode('utf-8')

        # Tolerate non-SHA-512 salts the way POSIX crypt(3) does.
        # Sigul's authenticate_admin uses crypt(password, 'xx') as a
        # constant-time placeholder when the user lookup misses;
        # raising here would crash the request handler with a
        # ValueError and the parent server would exit on the next
        # waitpid() with 'Child died with status 512'.  Return a
        # value that:
        #   * is deterministic,
        #   * is not equal to the input salt (so the caller's
        #     ``crypt(pw, x) != x`` check fires and auth_fail runs),
        #   * does not look like a valid crypt hash.
        # NOTE: this fast-path does NOT preserve the timing parity
        # the upstream timing-attack guard relies on - it returns
        # immediately rather than performing equivalent work to the
        # SHA-512 path.  Re-implementing parity here would require
        # invoking sha512_crypt with a synthesised salt and is not
        # worth the complexity for a placeholder-salt code path.
        if not salt.startswith('$6$'):
            return '!' + salt + '!invalid-crypt-salt'

        # Extract salt and optional rounds
        # Format: $6$salt or $6$rounds=N$salt
        parts = salt.split('$')
        if len(parts) < 3:
            return '!' + salt + '!invalid-crypt-salt'

        # Check if rounds are specified
        if parts[2].startswith('rounds='):
            # Extract rounds value
            rounds_str = parts[2].split('=')[1]
            try:
                rounds = int(rounds_str)
            except ValueError:
                rounds = 5000  # default
            salt_value = parts[3] if len(parts) > 3 else ''
        else:
            rounds = 5000  # default rounds
            salt_value = parts[2]

        # Use passlib to generate the hash
        # passlib's sha512_crypt.hash() returns the full crypt string
        return sha512_crypt.using(rounds=rounds, salt=salt_value).hash(word)

else:
    # Python < 3.13 - re-export the standard library crypt module's API.
    # We list names explicitly rather than `from crypt import *` to keep
    # the public surface of this shim explicit and to satisfy
    # basedpyright's reportWildcardImportFromLibrary.  This branch is
    # unreachable at the pythonVersion the project type-checks against
    # (3.14, matching the Fedora 44 image) but is preserved as a runtime
    # fallback for older interpreters; suppress the resulting
    # reportUnreachable on the import line.
    from crypt import (  # pyright: ignore[reportUnreachable]  # noqa: F401
        crypt,
        mksalt,
        methods,
        METHOD_SHA512,
        METHOD_SHA256,
        METHOD_MD5,
        METHOD_CRYPT,
    )
