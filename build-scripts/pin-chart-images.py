#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Pin the Sigul chart's container images to one release.

The chart carries a repository, tag and digest per component so that a
deployment names exactly the images it was tested against. Those values
are edited by hand between releases, so by release time they name
whichever build was current when somebody last touched the file -
publishing the chart without rewriting them ships a deployment contract
for the wrong images, and the version on the chart makes it look
deliberate.

All three fields move together. A release from a fork resolves its
digests against the fork's registry namespace, so rewriting the digest
alone would leave the chart naming the upstream images with digests
that exist only in the fork - references that resolve nowhere.

The rewrite is line-based rather than a round-trip through a YAML
parser. Every setting in values.yaml is documented by the comments
around it, and `helm show values` on the published chart is the only
place a consumer sees them; a re-serialised copy would drop all of it.

Every requested substitution must land. A selector that silently
matches nothing would leave a stale pin in place and still exit zero,
which is the failure this script exists to prevent.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import cast

# `images:` at column 0, components indented two spaces, their fields
# four. Anchored so that a `tag:` belonging to some other block cannot
# match while the parser believes it is inside a component.
IMAGES_KEY = re.compile(r"^images:\s*$")
COMPONENT_KEY = re.compile(r"^  (?P<name>[A-Za-z0-9_-]+):\s*$")
FIELD_KEY = re.compile(r"^    (?P<key>repository|tag|digest):\s")
# A non-indented, non-comment line ends the images block.
BLOCK_END = re.compile(r"^[^\s#]")
FIELDS = ("repository", "tag", "digest")


class PinError(RuntimeError):
    """Raised when the rewrite cannot be applied exactly as requested."""


def parse_digest(value: str) -> tuple[str, str]:
    """Split a ``component=sha256:...`` argument into its two parts.

    Args:
        value: The raw ``--digest`` argument.

    Returns:
        The component name and its digest.

    Raises:
        PinError: If the argument is malformed.
    """
    component, separator, digest = value.partition("=")
    if not separator or not component:
        raise PinError(f"expected component=digest, got {value!r}")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise PinError(f"not a sha256 digest: {digest!r}")
    return component, digest


def pin_images(text: str, image_base: str, tag: str, digests: dict[str, str]) -> str:
    """Rewrite the repository, tag and digest of each named component.

    Args:
        text: The contents of values.yaml.
        image_base: Registry and namespace holding the images, for
            example ``ghcr.io/owner/repo``.
        tag: Release tag to write, for example ``v1.2.3``.
        digests: Digest keyed by component name.

    Returns:
        The rewritten contents.

    Raises:
        PinError: If any component or field was not found exactly once.
    """
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    in_images = False
    component: str | None = None
    seen: set[tuple[str, str]] = set()

    for line in lines:
        if not in_images:
            in_images = bool(IMAGES_KEY.match(line))
            out.append(line)
            continue

        if BLOCK_END.match(line):
            in_images = False
            component = None
            out.append(line)
            continue

        component_match = COMPONENT_KEY.match(line)
        if component_match:
            component = component_match.group("name")
            out.append(line)
            continue

        field_match = FIELD_KEY.match(line)
        if field_match and component in digests:
            key = field_match.group("key")
            if (component, key) in seen:
                raise PinError(f"{component}.{key} appears more than once")
            seen.add((component, key))
            # The repository is rewritten alongside the digest because
            # the two have to agree. A release from a fork resolves its
            # digests against the fork's registry namespace, and
            # leaving the repository as committed would publish a
            # chart naming the upstream images with digests that only
            # exist in the fork.
            if key == "repository":
                value = f"{image_base}/{component}"
            elif key == "tag":
                value = tag
            else:
                value = f'"{digests[component]}"'
            out.append(f"    {key}: {value}\n")
            continue

        out.append(line)

    expected = {(name, key) for name in digests for key in FIELDS}
    missing = expected - seen
    if missing:
        detail = ", ".join(sorted(f"{name}.{key}" for name, key in missing))
        raise PinError(f"not found in values.yaml: {detail}")

    return "".join(out)


def main() -> int:
    """Parse arguments and rewrite the values file in place.

    Returns:
        Zero on success, one on failure.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    _ = parser.add_argument(
        "--values", required=True, type=Path, help="path to values.yaml"
    )
    _ = parser.add_argument(
        "--image-base",
        required=True,
        metavar="ghcr.io/OWNER/REPO",
        help="registry and namespace holding the images",
    )
    _ = parser.add_argument("--tag", required=True, help="release tag, e.g. v1.2.3")
    _ = parser.add_argument(
        "--digest",
        required=True,
        action="append",
        metavar="COMPONENT=sha256:...",
        help="digest for a component; repeat per component",
    )
    args = parser.parse_args()

    # argparse hands back Any; name the types once here so the rest of
    # the function is checkable.
    values_path = cast(Path, args.values)
    image_base = cast(str, args.image_base).rstrip("/")
    tag = cast(str, args.tag)
    digest_args = cast("list[str]", args.digest)

    try:
        digests = dict(parse_digest(item) for item in digest_args)
        original = values_path.read_text(encoding="utf-8")
        updated = pin_images(original, image_base, tag, digests)
    except PinError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    _ = values_path.write_text(updated, encoding="utf-8")
    for name in sorted(digests):
        print(f"pinned {name} to {image_base}/{name}:{tag} ({digests[name]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
