import base64
import hashlib
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

from generate_update_feed import SPARKLE, create_appcast, create_metadata


class UpdateFeedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.app = self.root / "Generated.app"
        (self.app / "Contents").mkdir(parents=True)
        self.info = {
            "CFBundleIdentifier": "local.maccy.capture",
            "CFBundleVersion": "1042.1",
            "CFBundleShortVersionString": "2.8.0",
            "LSMinimumSystemVersion": "14.0",
        }
        self.save_info()
        self.revision = "a" * 40
        self.archive = self.root / f"Maccy-Capture-2.8.0-{self.revision[:12]}-universal.zip"
        self.archive.write_bytes(b"synthetic archive fixture")
        self.signature = base64.b64encode(b"x" * 64).decode("ascii")

    def save_info(self):
        with (self.app / "Contents" / "Info.plist").open("wb") as target:
            plistlib.dump(self.info, target)

    def metadata(self):
        return create_metadata(self.archive, self.app, self.signature, self.revision)

    def test_metadata_contains_only_public_build_fields(self):
        metadata = self.metadata()
        self.assertEqual(metadata["version"], "1042.1")
        self.assertEqual(metadata["length"], len(b"synthetic archive fixture"))
        self.assertNotIn("PRIVATE", json.dumps(metadata))
        self.assertNotIn(str(self.root), json.dumps(metadata))

    def test_appcast_uses_exact_repository_asset_and_signature(self):
        root = ET.fromstring(create_appcast(self.metadata(), "fixture/capture", 123, self.archive))
        item = root.find("channel/item")
        self.assertEqual(item.find(f"{{{SPARKLE}}}version").text, "1042.1")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://api.github.com/repos/fixture/capture/releases/assets/123")
        self.assertEqual(enclosure.get(f"{{{SPARKLE}}}edSignature"), self.signature)
        self.assertEqual(enclosure.get(f"{{{SPARKLE}}}installationType"), "application")

    def test_changed_archive_is_not_published(self):
        metadata = self.metadata()
        self.archive.write_bytes(b"tampered archive")
        with self.assertRaises(ValueError):
            create_appcast(metadata, "fixture/capture", 123, self.archive)

    def test_unsigned_metadata_is_rejected(self):
        with self.assertRaises(ValueError):
            create_metadata(self.archive, self.app, "", self.revision)
        metadata = self.metadata()
        metadata["signature"] = ""
        with self.assertRaises(ValueError):
            create_appcast(metadata, "fixture/capture", 123, self.archive)

    def test_upstream_identity_and_wrong_revision_are_rejected(self):
        self.info["CFBundleIdentifier"] = "fixture.original.app"
        self.save_info()
        with self.assertRaises(ValueError):
            self.metadata()
        self.info["CFBundleIdentifier"] = "local.maccy.capture"
        self.save_info()
        with self.assertRaises(ValueError):
            create_metadata(self.archive, self.app, self.signature, "b" * 40)

    def test_malformed_repository_and_version_are_rejected(self):
        metadata = self.metadata()
        for repository in ["fixture/capture?leak=true", "https://fixture.invalid", "fixture/capture/other"]:
            with self.assertRaises(ValueError):
                create_appcast(metadata, repository, 123, self.archive)
        self.info["CFBundleVersion"] = "arbitrary"
        self.save_info()
        with self.assertRaises(ValueError):
            self.metadata()

    def test_publishing_uploads_packages_before_activating_the_feed(self):
        repository_root = pathlib.Path(__file__).resolve().parent.parent
        distribution = self.root / "dist"
        distribution.mkdir()
        archive = distribution / self.archive.name
        archive.write_bytes(self.archive.read_bytes())
        disk_image = archive.with_suffix(".dmg")
        disk_image.write_bytes(b"synthetic disk image")
        metadata = distribution / "UPDATE-METADATA.json"
        metadata.write_text(json.dumps(self.metadata()), encoding="utf-8")
        build_info = distribution / "BUILD-INFO.txt"
        build_info.write_text(f"Source revision: {self.revision}\n", encoding="utf-8")
        checksums = distribution / "SHA256SUMS.txt"
        checksums.write_text(
            "".join(
                f"{hashlib.sha256(source.read_bytes()).hexdigest()}  {source.name}\n"
                for source in [archive, disk_image, metadata, build_info]
            ),
            encoding="utf-8",
        )
        command_log = self.root / "commands.jsonl"
        mock_gh = self.root / "gh"
        mock_gh.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "arguments = sys.argv[1:]\n"
            "with open(os.environ['COMMAND_LOG'], 'a') as log:\n"
            "    log.write(json.dumps(arguments) + '\\n')\n"
            "if arguments[:2] == ['api', 'repos/fixture/capture/releases/tags/capture-latest']:\n"
            "    if 'select(.name ==' in arguments[-1]:\n"
            "        print('123')\n"
            "elif arguments[:2] == ['release', 'view']:\n"
            "    print('{}')\n",
            encoding="utf-8",
        )
        mock_gh.chmod(0o700)
        environment = os.environ | {
            "PATH": f"{self.root}{os.pathsep}{os.environ['PATH']}",
            "COMMAND_LOG": str(command_log),
            "GH_REPO": "fixture/capture",
            "GITHUB_SHA": self.revision,
            "GITHUB_ACTIONS": "true",
            "GITHUB_REF": "refs/heads/master",
            "GITHUB_EVENT_NAME": "push",
            "MACCY_DEFAULT_BRANCH": "master",
            "MACCY_DIST_DIR": str(distribution),
        }
        result = subprocess.run(
            ["bash", str(repository_root / "script/publish_prerelease.sh")],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = [json.loads(line) for line in command_log.read_text().splitlines()]
        uploads = [command for command in commands if command[:2] == ["release", "upload"]]
        self.assertIn(str(archive), uploads[0])
        self.assertIn(str(distribution / "capture-appcast.xml"), uploads[-1])
        edits = [command for command in commands if command[:2] == ["release", "edit"]]
        self.assertIn("--prerelease", edits[-1])
        self.assertIn("--draft=false", edits[-1])
        self.assertTrue((distribution / "capture-appcast.xml").exists())


if __name__ == "__main__":
    unittest.main()
