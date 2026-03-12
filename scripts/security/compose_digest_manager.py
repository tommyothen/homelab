#!/usr/bin/env python3
"""Manage immutable digest pinning for Docker Compose files.

Commands:
  - scan:    report floating and pinned image references
  - check:   fail if any floating image references remain
  - pin:     pin floating references to immutable digests
  - refresh: refresh existing digest pins that include pinned-from metadata

By default, updates are dry-run. Use --write to persist file changes.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


ACCEPT_HEADERS = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)

IMAGE_LINE_RE = re.compile(r"^(?P<prefix>\s*image:\s*)(?P<value>[^#\n]+?)(?P<suffix>\s*(?:#.*)?)$")
PINNED_FROM_RE = re.compile(r"pinned-from:\s*([^\s#]+)")
SHA_RE = re.compile(r"@sha256:[a-f0-9]{64}$")
TAG_DEFAULT_RE = re.compile(
    r"^(?P<base>[^\s]+):\$\{(?P<var>[A-Za-z_][A-Za-z0-9_]*)(?P<op>:-|-)(?P<default>[^}]+)\}$"
)


@dataclass(frozen=True)
class ImageRef:
    raw: str
    registry: str
    repository: str
    reference: str
    display_name: str


@dataclass
class FileStats:
    floating: int = 0
    pinned: int = 0
    skipped: int = 0
    updated: int = 0


class DigestResolutionError(RuntimeError):
    pass


def parse_image_ref(value: str) -> ImageRef:
    raw = value.strip().strip("\"'")
    if not raw:
        raise ValueError("empty image value")

    if "@sha256:" in raw:
        base, digest = raw.split("@", 1)
        registry, repository, _ = parse_registry_and_repo(base)
        return ImageRef(
            raw=raw,
            registry=registry,
            repository=repository,
            reference=digest,
            display_name=f"{registry}/{repository}",
        )

    if ":" in raw.rsplit("/", 1)[-1]:
        base, reference = raw.rsplit(":", 1)
    else:
        base, reference = raw, "latest"

    registry, repository, normalized = parse_registry_and_repo(base)
    return ImageRef(
        raw=raw,
        registry=registry,
        repository=repository,
        reference=reference,
        display_name=normalized,
    )


def parse_registry_and_repo(base: str) -> tuple[str, str, str]:
    parts = base.split("/", 1)
    first = parts[0]
    if "." in first or ":" in first or first == "localhost":
        registry = first
        repository = parts[1] if len(parts) > 1 else ""
    else:
        registry = "registry-1.docker.io"
        repository = base

    if registry == "docker.io":
        registry = "registry-1.docker.io"
    if registry == "registry-1.docker.io" and "/" not in repository:
        repository = f"library/{repository}"

    normalized = f"{registry}/{repository}"
    return registry, repository, normalized


def parse_bearer_challenge(header: str) -> dict[str, str]:
    challenge = header.strip()
    if not challenge.lower().startswith("bearer "):
        raise DigestResolutionError("unsupported auth challenge")
    attrs_raw = challenge[len("Bearer ") :]
    attrs: dict[str, str] = {}
    for part in re.finditer(r'(\w+)="([^"]+)"', attrs_raw):
        attrs[part.group(1)] = part.group(2)
    if "realm" not in attrs:
        raise DigestResolutionError("auth challenge missing realm")
    return attrs


def fetch_bearer_token(challenge: dict[str, str]) -> str:
    query = {}
    if "service" in challenge:
        query["service"] = challenge["service"]
    if "scope" in challenge:
        query["scope"] = challenge["scope"]
    url = challenge["realm"]
    if query:
        url = f"{url}?{urllib.parse.urlencode(query)}"

    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "compose-digest-manager/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        raise DigestResolutionError(f"failed to fetch auth token: {exc}") from exc

    token = payload.get("token") or payload.get("access_token")
    if not token:
        raise DigestResolutionError("token response missing token")
    return token


def resolve_digest(image: ImageRef) -> str:
    url = f"https://{image.registry}/v2/{image.repository}/manifests/{image.reference}"
    headers = {
        "Accept": ACCEPT_HEADERS,
        "User-Agent": "compose-digest-manager/1.0",
    }

    req = urllib.request.Request(url, method="HEAD", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            digest = resp.headers.get("Docker-Content-Digest", "")
    except urllib.error.HTTPError as exc:
        if exc.code != 401:
            raise DigestResolutionError(f"registry error {exc.code} for {image.raw}") from exc
        challenge_header = exc.headers.get("Www-Authenticate", "")
        challenge = parse_bearer_challenge(challenge_header)
        token = fetch_bearer_token(challenge)
        auth_headers = dict(headers)
        auth_headers["Authorization"] = f"Bearer {token}"
        auth_req = urllib.request.Request(url, method="HEAD", headers=auth_headers)
        try:
            with urllib.request.urlopen(auth_req, timeout=20) as resp:
                digest = resp.headers.get("Docker-Content-Digest", "")
        except urllib.error.URLError as auth_exc:
            raise DigestResolutionError(f"auth registry lookup failed for {image.raw}: {auth_exc}") from auth_exc
    except urllib.error.URLError as exc:
        raise DigestResolutionError(f"failed registry lookup for {image.raw}: {exc}") from exc

    if not digest.startswith("sha256:"):
        raise DigestResolutionError(f"registry did not return digest for {image.raw}")
    return digest


def pin_line(image_text: str, digest: str, pinned_from: str) -> str:
    base = image_text.split("@sha256:", 1)[0] if "@sha256:" in image_text else image_text
    if ":" in base.rsplit("/", 1)[-1]:
        base = base.rsplit(":", 1)[0]
    return f"{base}@{digest} # pinned-from: {pinned_from}"


def resolve_variable_default_ref(value: str) -> str | None:
    match = TAG_DEFAULT_RE.match(value)
    if not match:
        return None
    return f"{match.group('base')}:{match.group('default')}"


def process_file(
    file_path: Path,
    mode: str,
    resolver: Callable[[ImageRef], str],
) -> tuple[FileStats, str, list[str]]:
    stats = FileStats()
    updates: list[str] = []
    lines = file_path.read_text(encoding="utf-8").splitlines()
    out_lines: list[str] = []

    for lineno, line in enumerate(lines, start=1):
        match = IMAGE_LINE_RE.match(line)
        if not match:
            out_lines.append(line)
            continue

        prefix = match.group("prefix")
        value = match.group("value").strip()
        suffix = match.group("suffix") or ""

        variable_resolved = resolve_variable_default_ref(value)
        if "${" in value and not variable_resolved:
            stats.skipped += 1
            out_lines.append(line)
            updates.append(f"{file_path}:{lineno} skipped variable image ref: {value}")
            continue

        pinned_from_match = PINNED_FROM_RE.search(suffix)

        if SHA_RE.search(value):
            stats.pinned += 1
            if mode != "refresh":
                out_lines.append(line)
                continue
            if not pinned_from_match:
                stats.skipped += 1
                out_lines.append(line)
                updates.append(f"{file_path}:{lineno} skipped pinned image without pinned-from metadata")
                continue
            source_ref = pinned_from_match.group(1)
            image = parse_image_ref(source_ref)
            try:
                digest = resolver(image)
            except DigestResolutionError as exc:
                stats.skipped += 1
                out_lines.append(line)
                updates.append(f"{file_path}:{lineno} refresh failed for {source_ref}: {exc}")
                continue
            new_value = pin_line(value, digest, source_ref)
            if new_value != value + ("" if not suffix else ""):
                stats.updated += 1
                updates.append(f"{file_path}:{lineno} refreshed {source_ref} -> {digest}")
            out_lines.append(f"{prefix}{new_value}")
            continue

        stats.floating += 1
        if mode == "check":
            out_lines.append(line)
            updates.append(f"{file_path}:{lineno} floating image: {value}")
            continue
        if mode == "refresh":
            out_lines.append(line)
            updates.append(f"{file_path}:{lineno} floating image unchanged during refresh: {value}")
            continue

        source_value = variable_resolved or value
        image = parse_image_ref(source_value)
        try:
            digest = resolver(image)
        except DigestResolutionError as exc:
            stats.skipped += 1
            out_lines.append(line)
            updates.append(f"{file_path}:{lineno} pin failed for {source_value}: {exc}")
            continue
        new_value = pin_line(source_value, digest, source_value)
        stats.updated += 1
        updates.append(f"{file_path}:{lineno} pinned {source_value} -> {digest}")
        out_lines.append(f"{prefix}{new_value}")

    output = "\n".join(out_lines) + "\n"
    return stats, output, updates


def collect_compose_files(root: Path) -> list[Path]:
    files = sorted(root.glob("stacks/**/docker-compose.yml"))
    return [p for p in files if p.is_file()]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Pin and refresh Docker Compose image digests")
    sub = parser.add_subparsers(dest="command", required=True)

    for command in ("scan", "check", "pin", "refresh"):
        cmd = sub.add_parser(command)
        cmd.add_argument("--root", default=".", help="repository root")
        cmd.add_argument("--write", action="store_true", help="write file changes")
        cmd.add_argument("--json", action="store_true", help="print machine-readable output")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    root = Path(args.root).resolve()
    files = collect_compose_files(root)
    if not files:
        print("No compose files found.", file=sys.stderr)
        return 1

    mode = args.command
    resolver = resolve_digest
    total = FileStats()
    changes: dict[Path, str] = {}
    update_logs: list[str] = []

    for file_path in files:
        file_mode = "check" if mode in ("scan", "check") else mode
        stats, output, updates = process_file(file_path, file_mode, resolver)
        total.floating += stats.floating
        total.pinned += stats.pinned
        total.skipped += stats.skipped
        total.updated += stats.updated
        update_logs.extend(updates)
        if output != file_path.read_text(encoding="utf-8"):
            changes[file_path] = output

    result = {
        "command": mode,
        "files": len(files),
        "floating": total.floating,
        "pinned": total.pinned,
        "skipped": total.skipped,
        "updated": total.updated,
        "changed_files": [str(path.relative_to(root)) for path in changes.keys()],
        "details": update_logs,
    }

    if getattr(args, "json", False):
        print(json.dumps(result, indent=2))
    else:
        print(f"Command: {mode}")
        print(f"Compose files: {result['files']}")
        print(f"Floating: {result['floating']}  Pinned: {result['pinned']}  Skipped: {result['skipped']}  Updated: {result['updated']}")
        for line in update_logs:
            print(f"- {line}")

    if mode in ("pin", "refresh") and args.write:
        for file_path, content in changes.items():
            file_path.write_text(content, encoding="utf-8")

    if mode == "check" and total.floating > 0:
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
