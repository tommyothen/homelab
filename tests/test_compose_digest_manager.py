import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts/security/compose_digest_manager.py"
SPEC = importlib.util.spec_from_file_location("compose_digest_manager", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ComposeDigestManagerTests(unittest.TestCase):
    def test_parse_image_ref_defaults_docker_hub_latest(self):
        ref = MODULE.parse_image_ref("redis")
        self.assertEqual(ref.registry, "registry-1.docker.io")
        self.assertEqual(ref.repository, "library/redis")
        self.assertEqual(ref.reference, "latest")

    def test_process_file_pin_mode_pins_floating_refs(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "docker-compose.yml"
            path.write_text("services:\n  app:\n    image: redis:7\n", encoding="utf-8")

            stats, output, updates = MODULE.process_file(
                path,
                "pin",
                lambda image: "sha256:" + "a" * 64,
            )

            self.assertEqual(stats.floating, 1)
            self.assertEqual(stats.updated, 1)
            self.assertIn("redis@sha256:", output)
            self.assertIn("pinned-from: redis:7", output)
            self.assertEqual(len(updates), 1)

    def test_process_file_refresh_mode_uses_pinned_from(self):
        digest_a = "sha256:" + "a" * 64
        digest_b = "sha256:" + "b" * 64
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "docker-compose.yml"
            path.write_text(
                (
                    "services:\n"
                    "  app:\n"
                    f"    image: redis@{digest_a} # pinned-from: redis:7\n"
                ),
                encoding="utf-8",
            )

            stats, output, _ = MODULE.process_file(
                path,
                "refresh",
                lambda image: digest_b,
            )

            self.assertEqual(stats.pinned, 1)
            self.assertEqual(stats.updated, 1)
            self.assertIn(f"redis@{digest_b}", output)
            self.assertIn("pinned-from: redis:7", output)

    def test_process_file_pins_variable_refs_with_default_tag(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "docker-compose.yml"
            path.write_text("services:\n  app:\n    image: ghcr.io/x/y:${TAG:-latest}\n", encoding="utf-8")

            stats, output, updates = MODULE.process_file(
                path,
                "pin",
                lambda image: "sha256:" + "a" * 64,
            )

            self.assertEqual(stats.skipped, 0)
            self.assertEqual(stats.updated, 1)
            self.assertIn("ghcr.io/x/y@sha256:", output)
            self.assertIn("pinned-from: ghcr.io/x/y:latest", output)
            self.assertEqual(len(updates), 1)

    def test_process_file_skips_variable_refs_without_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "docker-compose.yml"
            path.write_text("services:\n  app:\n    image: ghcr.io/x/y:${TAG}\n", encoding="utf-8")

            stats, output, updates = MODULE.process_file(
                path,
                "pin",
                lambda image: "sha256:" + "a" * 64,
            )

            self.assertEqual(stats.skipped, 1)
            self.assertEqual(stats.updated, 0)
            self.assertIn("${TAG}", output)
            self.assertEqual(len(updates), 1)

    def test_process_file_records_resolver_failures(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "docker-compose.yml"
            path.write_text("services:\n  app:\n    image: redis:7\n", encoding="utf-8")

            def fail(_image):
                raise MODULE.DigestResolutionError("boom")

            stats, output, updates = MODULE.process_file(path, "pin", fail)

            self.assertEqual(stats.updated, 0)
            self.assertEqual(stats.skipped, 1)
            self.assertIn("image: redis:7", output)
            self.assertIn("pin failed", updates[0])


if __name__ == "__main__":
    unittest.main()
