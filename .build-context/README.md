<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Build Context Directory

This directory provides optional build-time dependencies for local development
and debugging builds.

## Purpose

The `.build-context/` directory provides a location for placing source code and
other files that Docker image builds require for local development and
debugging scenarios.

## Structure

### `sigul/`

Use this directory for local development builds when you want to build
against a specific version of the Sigul source code.

**Usage:**

1. Clone the Sigul repository into this directory:

   ```bash
   git clone https://pagure.io/sigul.git .build-context/sigul/
   ```

2. The Dockerfiles will copy this source code into the build context
3. Build scripts can use this local copy instead of cloning from upstream

**CI/Production Builds:**

- In CI and production builds, this directory contains a `.gitkeep` file
- The Dockerfiles will copy an empty directory (which is safe)
- Build scripts will clone Sigul from upstream as needed

## Gitignore Configuration

The `.gitignore` configuration excludes all content in `sigul/*` except the
`.gitkeep` file:

```gitignore
.build-context/sigul/*
!.build-context/sigul/.gitkeep
```

This means:

- Git tracks the directory structure
- Git does not track actual source code (local development)
- CI builds work without any local source code

## Why This Approach?

This design allows:

✅ **Local Development** - Developers can place Sigul source code here for
   debugging and testing modifications

✅ **CI Compatibility** - CI builds work without requiring local source code,
   as the directory exists but is empty

✅ **No Git Bloat** - The actual Sigul source code is not committed to this
   repository

✅ **Build Flexibility** - Build scripts can detect whether local source exists
   and adjust behavior accordingly

## Notes

- The `.gitkeep` file must remain in `sigul/` for Docker builds to succeed
- Do not commit actual Sigul source code to this repository
- Docker image builds use this directory, not runtime processes
