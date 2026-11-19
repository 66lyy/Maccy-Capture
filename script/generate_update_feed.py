import argparse
import base64
import datetime
import hashlib
import json
import pathlib
import plistlib
import re
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def create_metadata(archive, app, signature, revision):
    with (app / "Contents" / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info["CFBundleIdentifier"] != "local.maccy.capture":
        raise ValueError("Unexpected application identifier")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Expected a complete source revision")
    if not archive.name.endswith(f"-{revision[:12]}-universal.zip"):
        raise ValueError("Archive does not belong to this source revision")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Expected an Ed25519 signature")
    version = info["CFBundleVersion"]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", version):
        raise ValueError("Expected a numeric build version")
    return {
        "version": version,
        "shortVersion": info["CFBundleShortVersionString"],
        "minimumSystemVersion": info["LSMinimumSystemVersion"],
        "filename": archive.name,
        "length": archive.stat().st_size,
        "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "signature": signature,
        "sourceRevision": revision,
    }


def create_appcast(metadata, repository, asset_id, archive):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or asset_id <= 0:
        raise ValueError("Expected a GitHub repository and asset identifier")
    if metadata["filename"] != archive.name or metadata["length"] != archive.stat().st_size:
        raise ValueError("Update archive metadata mismatch")
    if hashlib.sha256(archive.read_bytes()).hexdigest() != metadata["sha256"]:
        raise ValueError("Update archive checksum mismatch")
    if len(base64.b64decode(metadata["signature"], validate=True)) != 64:
        raise ValueError("Missing update signature")
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Maccy Capture updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f'Maccy Capture {metadata["shortVersion"]} ({metadata["version"]})'
    ET.SubElement(item, "pubDate").text = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S GMT"
    )
    for key in ["version", "shortVersion", "minimumSystemVersion"]:
        tag = "shortVersionString" if key == "shortVersion" else key
        ET.SubElement(item, f"{{{SPARKLE}}}{tag}").text = metadata[key]
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": f"https://api.github.com/repos/{repository}/releases/assets/{asset_id}",
            "length": str(metadata["length"]),
            "type": "application/octet-stream",
            f"{{{SPARKLE}}}edSignature": metadata["signature"],
            f"{{{SPARKLE}}}installationType": "application",
        },
    )
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    metadata = subparsers.add_parser("metadata")
    metadata.add_argument("--archive", type=pathlib.Path, required=True)
    metadata.add_argument("--app", type=pathlib.Path, required=True)
    metadata.add_argument("--signature", required=True)
    metadata.add_argument("--revision", required=True)
    metadata.add_argument("--output", type=pathlib.Path, required=True)
    appcast = subparsers.add_parser("appcast")
    appcast.add_argument("--metadata", type=pathlib.Path, required=True)
    appcast.add_argument("--repository", required=True)
    appcast.add_argument("--asset-id", type=int, required=True)
    appcast.add_argument("--archive", type=pathlib.Path, required=True)
    appcast.add_argument("--output", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    if arguments.command == "metadata":
        result = create_metadata(arguments.archive, arguments.app, arguments.signature, arguments.revision)
        arguments.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    else:
        result = create_appcast(
            json.loads(arguments.metadata.read_text(encoding="utf-8")),
            arguments.repository,
            arguments.asset_id,
            arguments.archive,
        )
        arguments.output.write_bytes(result)


if __name__ == "__main__":
    main()
