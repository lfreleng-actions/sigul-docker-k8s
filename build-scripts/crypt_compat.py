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
    except ImportError:
        raise ImportError(
            "passlib is required for crypt module compatibility in Python 3.13+. "
            "Install it with: pip install passlib"
        )

    def crypt(word, salt):
        """
        Hash a password using SHA-512 crypt.

        Args:
            word: The password to hash (str or bytes)
            salt: The salt string (must start with $6$ for SHA-512)

        Returns:
            The hashed password string in crypt format

        Raises:
            ValueError: If salt format is not supported
        """
        # Convert bytes to string if needed
        if isinstance(word, bytes):
            word = word.decode('utf-8')

        # Validate salt format
        if not salt.startswith('$6$'):
            raise ValueError(
                f"Only SHA-512 crypt ($6$) is supported, got: {salt[:3]}"
            )

        # Extract salt and optional rounds
        # Format: $6$salt or $6$rounds=N$salt
        parts = salt.split('$')
        if len(parts) < 3:
            raise ValueError(f"Invalid salt format: {salt}")

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
    # Python < 3.13 - use the standard library crypt module
    from crypt import *  # noqa: F401,F403
