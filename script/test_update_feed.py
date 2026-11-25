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
    def test_stable_downloads_only_the_matching_successful_build(self):
        script = pathlib.Path(__file__).with_name("publish_stable.sh").resolve()
        mock = self.root / "gh"
        mock.write_text('''#!/usr/bin/env bash
set -eu
case "$1:$2" in
  api:*/releases/tags/*) exit 1;;
  api:*/commits/tags/*) echo "$FIXTURE_SHA";;
  api:*/compare/*) echo identical;;
  api:*/actions/workflows/*) [[ "$2" == *"status=success&head_sha=$FIXTURE_SHA&"* ]] || exit 1; echo "$BUILD_RUN";;
  run:download)
    printf '%s %s' "$3" "$5" > "$RUNNER_TEMP/selected"
    mkdir -p "$7"; echo 'invalid fixture checksum' > "$7/SHA256SUMS.txt";;
  *) exit 99;;
esac
''')
        mock.chmod(0o755)
        tag = 'maccy-capture-v2.11.0'
        for build_run in ['21 8', '21 invalid', 'invalid 8']:
            with self.subTest(build_run=build_run):
                environment = {
                    'PATH': f"{self.root}:{os.environ['PATH']}", 'RUNNER_TEMP': str(self.root),
                    'GITHUB_ACTIONS': 'true', 'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': f'refs/tags/{tag}',
                    'GH_REPO': 'fixture/capture', 'MACCY_DEFAULT_BRANCH': 'master',
                    'MACCY_RELEASE_TAG': tag, 'FIXTURE_SHA': self.revision, 'BUILD_RUN': build_run,
                }
                selected = self.root / 'selected'
                selected.unlink(missing_ok=True)
                result = subprocess.run(['bash', str(script)], env=environment, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotEqual(result.returncode, 99)
                if build_run == '21 8':
                    self.assertEqual(selected.read_text(), '21 Maccy-Capture-macOS-universal-8')
                else:
                    self.assertIn('No successful default-branch build', result.stderr)
                    self.assertFalse(selected.exists())

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

    def test_stable_tag_push_requires_a_successful_build_of_that_commit(self):
        script = pathlib.Path(__file__).resolve().with_name("publish_stable.sh")
        tag = "maccy-capture-v2.11.0"
        command_log = self.root / "stable-commands.log"
        mock_gh = self.root / "gh"
        mock_gh.write_text(
            "#!/bin/sh\n"
            'printf "%s\\n" "$2" >> "$COMMAND_LOG"\n'
            'case "$2" in\n'
            '  */releases/tags/*) exit 1 ;;\n'
            '  */commits/tags/*) [ "$TAG_EXISTS" = yes ] && printf "%s\\n" "$REVISION" ;;\n'
            '  */compare/*) printf "%s\\n" "$COMPARE_STATUS" ;;\n'
            '  */actions/workflows/*) exit 0 ;;\n'
            "  *) exit 1 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        mock_gh.chmod(0o700)
        environment = os.environ | {
            "PATH": f"{self.root}{os.pathsep}{os.environ['PATH']}",
            "COMMAND_LOG": str(command_log),
            "REVISION": self.revision,
            "TAG_EXISTS": "yes",
            "COMPARE_STATUS": "ahead",
            "GH_REPO": "fixture/capture",
            "GITHUB_ACTIONS": "true",
            "GITHUB_REF": f"refs/tags/{tag}",
            "GITHUB_EVENT_NAME": "push",
            "MACCY_DEFAULT_BRANCH": "master",
            "MACCY_RELEASE_TAG": tag,
        }

        def run(**overrides):
            command_log.write_text("", encoding="utf-8")
            result = subprocess.run(
                ["bash", str(script)], env=environment | overrides, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            return result.stderr, command_log.read_text().splitlines()

        stderr, commands = run()
        self.assertIn("No successful default-branch build", stderr)
        self.assertEqual(commands, [
            f"repos/fixture/capture/releases/tags/{tag}",
            f"repos/fixture/capture/commits/tags/{tag}",
            f"repos/fixture/capture/compare/{self.revision}...master",
            "repos/fixture/capture/actions/workflows/build-capture.yml/"
            f"runs?branch=master&event=push&status=success&head_sha={self.revision}&per_page=1",
        ])
        stderr, commands = run(TAG_EXISTS="no")
        self.assertIn("Could not resolve the release tag", stderr)
        self.assertEqual(commands[-1], f"repos/fixture/capture/commits/tags/{tag}")
        stderr, commands = run(COMPARE_STATUS="diverged")
        self.assertIn("is not on master", stderr)
        self.assertEqual(commands[-1], f"repos/fixture/capture/compare/{self.revision}...master")
        for invalid in [
            {"GITHUB_REF": "refs/heads/master"},
            {"GITHUB_REF": "refs/tags/maccy-capture-v2.11.1"},
            {"MACCY_RELEASE_TAG": f"{tag}-build1120.1", "GITHUB_REF": f"refs/tags/{tag}-build1120.1"},
            {"MACCY_RELEASE_TAG": "capture-v2.11.0", "GITHUB_REF": "refs/tags/capture-v2.11.0"},
        ]:
            with self.subTest(invalid=invalid):
                _, commands = run(**invalid)
                self.assertEqual(commands, [])

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
        asset_store = self.root / "assets.json"
        mock_gh = self.root / "gh"
        mock_gh.write_text(
            f"#!{sys.executable}\n"
            "import hashlib, json, os, pathlib, sys\n"
            "arguments = sys.argv[1:]\n"
            "store = pathlib.Path(os.environ['ASSET_STORE'])\n"
            "exists = store.exists()\n"
            "assets = json.loads(store.read_text()) if exists else {}\n"
            "draft_marker = pathlib.Path(os.environ['ASSET_STORE'] + '.draft')\n"
            "def snapshot():\n"
            "    store.write_text(json.dumps(assets))\n"
            "with open(os.environ['COMMAND_LOG'], 'a') as log:\n"
            "    log.write(json.dumps(arguments) + '\\n')\n"
            "if any('capture-latest' in arg for arg in arguments): sys.exit('rolling release must not be touched')\n"
            "if arguments[:2] == ['api', 'repos/fixture/capture/releases?per_page=30']:\n"
            "    print(json.dumps([\n"
            "        {'tag_name': 'maccy-capture-v2.7.0', 'draft': False, 'published_at': '2026-11-20T07:26:36Z'},\n"
            "        {'tag_name': 'maccy-capture-v2.8.0-build1041.1', 'draft': False, 'published_at': '2026-11-20T07:36:57Z'}]))\n"
            "elif arguments[0] == 'api' and '/compare/' in arguments[1]:\n"
            "    print(json.dumps({'commits': [\n"
            "        {'sha': 'b'*40, 'parents': [{}], 'commit': {'message': 'First change\\nbody'}},\n"
            "        {'sha': 'c'*40, 'parents': [{}, {}], 'commit': {'message': 'Merge omitted'}},\n"
            "        {'sha': 'a'*40, 'parents': [{}], 'commit': {'message': 'Newest change'}}],\n"
            "        'files': [{'patch': 'x' * 300000}]}))\n"
            "elif arguments[0] == 'api' and ('/releases/tags/' in arguments[1] or\n"
            "        arguments[1] == 'https://api.github.com/repos/fixture/capture/releases/99'):\n"
            "    if '/releases/tags/' in arguments[1] and draft_marker.exists():\n"
            "        sys.exit('HTTP 404: Not Found')\n"
            "    response = json.dumps({'assets': list(assets.values())})\n"
            "    print(response)\n"
            "elif arguments[:2] == ['release', 'upload']:\n"
            "    for path in map(pathlib.Path, arguments[3:]):\n"
            "        identifier = max([122] + [asset['id'] for asset in assets.values()]) + 1\n"
            "        if path.name in assets:\n"
            "            sys.exit('cannot replace an immutable asset')\n"
            "        assets[path.name] = {'id': identifier, 'name': path.name, 'state': 'uploaded',\n"
            "            'created_at': '2026-11-20T02:00:00Z',\n"
            "            'digest': 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()}\n"
            "        snapshot()\n"
            "elif arguments[:2] == ['release', 'delete-asset']:\n"
            "    del assets[arguments[3]]\n"
            "    snapshot()\n"
            "elif arguments[:2] == ['release', 'view']:\n"
            "    if not exists: sys.exit(1)\n"
            "    print('https://api.github.com/repos/fixture/capture/releases/99' if 'apiUrl' in arguments else '{}')\n"
            "elif arguments[:2] == ['release', 'create']:\n"
            "    draft_marker.touch()\n"
            "    snapshot()\n"
            "elif arguments[:2] == ['release', 'edit']:\n"
            "    assert '--draft=false' in arguments and '--prerelease' in arguments\n"
            "    if draft_marker.exists(): draft_marker.unlink()\n"
            "if '--notes-file' in arguments:\n"
            "    pathlib.Path(os.environ['NOTES_COPY']).write_text(pathlib.Path(arguments[arguments.index('--notes-file')+1]).read_text())\n",
            encoding="utf-8",
        )
        mock_gh.chmod(0o700)
        environment = os.environ | {
            "PATH": f"{self.root}{os.pathsep}{os.environ['PATH']}",
            "COMMAND_LOG": str(command_log),
            "ASSET_STORE": str(asset_store),
            "NOTES_COPY": str(self.root / "notes.md"),
            "GH_REPO": "fixture/capture",
            "GITHUB_SHA": self.revision,
            "GITHUB_ACTIONS": "true",
            "GITHUB_REF": "refs/heads/master",
            "GITHUB_EVENT_NAME": "push",
            "MACCY_DEFAULT_BRANCH": "master",
            "MACCY_DIST_DIR": str(distribution),
        }
        for _ in range(2):  # A retry must keep the same feed and archive IDs.
            result = subprocess.run(
                ["bash", str(repository_root / "script/publish_prerelease.sh")],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
        commands = [json.loads(line) for line in command_log.read_text().splitlines()]
        compares = [c for c in commands if c[0] == 'api' and '/compare/' in c[1]]
        self.assertEqual(compares, [
            ['api', f'repos/fixture/capture/compare/maccy-capture-v2.8.0-build1041.1...{self.revision}']
        ] * 2)
        tag = "maccy-capture-v2.8.0-build1042.1"
        creates = [c for c in commands if c[:2] == ["release", "create"]]
        self.assertEqual(len(creates), 1)
        self.assertEqual(creates[0][2], tag)
        self.assertIn("Maccy Capture 2.8.0 test build 1042.1", creates[0])
        for option in ["--draft", "--prerelease", "--latest=false", self.revision]:
            self.assertIn(option, creates[0])
        build_commands = [c for c in commands if len(c) > 2 and c[2] == tag]
        build_uploads = [c for c in build_commands if c[1] == "upload"]
        self.assertEqual(len(build_uploads), 6, "retry must skip all identical assets")
        enclosure = ET.parse(distribution / "capture-appcast.xml").find("channel/item/enclosure")
        uploaded_zip = json.loads(asset_store.read_text())[archive.name]
        self.assertEqual(enclosure.get("url"),
                         f"https://api.github.com/repos/fixture/capture/releases/assets/{uploaded_zip['id']}")
        self.assertEqual(enclosure.get("length"), str(archive.stat().st_size))
        self.assertEqual(enclosure.get(f"{{{SPARKLE}}}edSignature"), self.signature)
        self.assertTrue(all('--clobber' not in c for c in build_uploads))
        self.assertGreater(build_commands.index(next(c for c in build_commands if c[1] == 'edit')),
                           max(i for i, c in enumerate(build_commands) if c[1] == 'upload'))
        notes = (self.root / "notes.md").read_text()
        self.assertIn("Changes / 更新内容", notes)
        self.assertLess(notes.index('Newest change'), notes.index('First change'))
        self.assertNotIn('Merge omitted', notes)
        build_store = asset_store
        published_assets = json.loads(build_store.read_text())
        published_assets[archive.name]['digest'] = 'sha256:wrong'
        build_store.write_text(json.dumps(published_assets))
        mismatch = subprocess.run(
            ['bash', str(repository_root / 'script/publish_prerelease.sh')],
            env=environment, capture_output=True, text=True, check=False,
        )
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn('refusing to replace it', mismatch.stderr)
        commands = [json.loads(line) for line in command_log.read_text().splitlines()]
        self.assertFalse(any("capture-latest" in arg for command in commands for arg in command))


if __name__ == "__main__":
    unittest.main()
