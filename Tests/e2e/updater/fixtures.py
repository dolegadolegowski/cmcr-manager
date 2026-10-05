"""Writes the fake GitHub API answers for the self-update tests.

    python3 fixtures.py ROOT

Expects signed releases in ROOT/www/files/<tag>/ (zip, cmcr-update.json, cmcr-update.json.sig) for
v1.0.1, v1.0.2, v1.0.3, v1.0.4 and v1.1.0-beta.1, and creates the tampered variants next to them.
"""
import hashlib
import json
import os
import shutil
import sys

ROOT = sys.argv[1]
WWW = os.path.join(ROOT, "www")
FILES = os.path.join(WWW, "files")
API = os.path.join(WWW, "api")
os.makedirs(API, exist_ok=True)


def zip_name(tag):
    return "CMCR-Manager-%s.zip" % tag[1:]


def release(tag, files_tag=None, prerelease=False, manifest_url=None, archive_url=None, digest=True, fake_digest=None,
            skip=()):
    files_tag = files_tag or tag
    assets = []
    for name in sorted(os.listdir(os.path.join(FILES, files_tag))):
        if name in skip:
            continue
        data = open(os.path.join(FILES, files_tag, name), "rb").read()
        asset = {"name": name, "size": len(data),
                 "browser_download_url": "__BASE__/files/%s/%s" % (files_tag, name)}
        if digest:
            asset["digest"] = "sha256:" + (fake_digest if fake_digest and name.endswith(".zip")
                                           else hashlib.sha256(data).hexdigest())
        if name == "cmcr-update.json" and manifest_url:
            asset["browser_download_url"] = manifest_url
        if name.endswith(".zip") and archive_url:
            asset["browser_download_url"] = archive_url
        assets.append(asset)
    return {"tag_name": tag, "name": "CMCR Manager %s" % tag[1:],
            "body": "## Zmiany %s\n* punkt z opisu wydania na GitHubie" % tag,
            "html_url": "__BASE__/web/test/cmcr/releases/tag/%s" % tag,
            "published_at": "2026-10-04T10:00:00Z", "draft": False, "prerelease": prerelease, "assets": assets}


def write(name, obj):
    with open(os.path.join(API, name + ".json"), "w") as f:
        json.dump(obj, f, indent=1)


ok = "v1.0.1"
# Manifest bytes changed after signing: the signature no longer matches.
os.makedirs(os.path.join(FILES, "forged"), exist_ok=True)
manifest = json.load(open(os.path.join(FILES, ok, "cmcr-update.json")))
manifest["sha256"] = "0" * 64
json.dump(manifest, open(os.path.join(FILES, "forged", "cmcr-update.json"), "w"), indent=2)
# Archive replaced by other bytes of the same size, and by a bigger file.
original = open(os.path.join(FILES, ok, zip_name(ok)), "rb").read()
for variant, data in (("tampered", bytes(b ^ 0xFF for b in original[:64]) + original[64:]),
                      ("big", original + b"\0" * 4096)):
    os.makedirs(os.path.join(FILES, variant), exist_ok=True)
    open(os.path.join(FILES, variant, zip_name(ok)), "wb").write(data)

write("api-ok-latest", release(ok))
write("api-ok-list", [release(ok), release("v1.1.0-beta.1", prerelease=True), release("v1.0.2")])
write("api-bad-latest", release("v1.0.2"))
write("api-slow-latest", release("v1.0.3"))
write("api-crash-latest", release("v1.0.4"))
write("api-forged-latest", release(ok, manifest_url="__BASE__/files/forged/cmcr-update.json"))
write("api-relabel-latest", release("v9.9.9", files_tag=ok))
write("api-digest-latest", release(ok, fake_digest="f" * 64))
write("api-tampered-latest", release(ok, archive_url="__BASE__/files/tampered/%s" % zip_name(ok), digest=False))
write("api-big-latest", release(ok, archive_url="__BASE__/files/big/%s" % zip_name(ok), digest=False))
write("api-nomanifest-latest", release(ok, skip=("cmcr-update.json", "cmcr-update.json.sig")))

# github.com/<repo>/releases/latest/download/… and …/releases/download/<tag>/… (used when the API is rate limited)
web = os.path.join(WWW, "web", "test", "cmcr", "releases")
os.makedirs(os.path.join(web, "latest", "download"), exist_ok=True)
for name in ("cmcr-update.json", "cmcr-update.json.sig"):
    shutil.copy(os.path.join(FILES, ok, name), os.path.join(web, "latest", "download", name))
shutil.copytree(os.path.join(FILES, ok), os.path.join(web, "download", ok))
print("fixtures ready")
