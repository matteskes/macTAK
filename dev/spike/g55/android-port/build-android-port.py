#!/usr/bin/env python3
"""Build the 5.5 android-port compile substitute (android-port-3.1.0-g55).

The G0 transplant (dev/spike/g0/transplants/android-port-3.1.0.jar) plus
the compile stubs in dev/spike/g55/android-port/src, which replace or add
classes the 5.5 kernel needs. Compile-time only, like its base: the stub
bodies return defaults.

The jar is deterministic (sorted entries, fixed timestamps), so its
SHA-256 depends only on the base jar and the stub sources.

usage: build-android-port.py OUT_DIR
out:   OUT_DIR/android-port-3.1.0-g55.jar and .pom
"""
import os
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
BASE_JAR = os.path.join(DEV, "spike", "g0", "transplants", "android-port-3.1.0.jar")
STUB_SRC = os.path.join(HERE, "src")
VERSION = "3.1.0-g55"
FIXED_ZIP_TIME = (2008, 1, 1, 0, 0, 0)  # the base jar's own dex2jar timestamp

POM = """<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>gov.tak.support</groupId>
  <artifactId>android-port</artifactId>
  <version>{version}</version>
  <packaging>jar</packaging>
  <description>macTAK 5.5 spike transplant: the G0 android-port-3.1.0 substitute (android.jar API-33 framework signatures + TAK classes from the public ATAK-CIV 5.5.1.8 apk) plus the compile stubs in dev/spike/g55/android-port/src. Compile-time substitute for the TAK-artifactory-only artifact; not for runtime use.</description>
  <dependencies>
    <dependency><groupId>org.slf4j</groupId><artifactId>slf4j-api</artifactId><version>1.7.30</version></dependency>
  </dependencies>
</project>
"""


def java8_tool(name):
    home = os.environ.get("G55_JDK8_HOME") or subprocess.run(
        ["/usr/libexec/java_home", "-v", "1.8"],
        check=True, capture_output=True, text=True).stdout.strip()
    return os.path.join(home, "bin", name)


def stub_sources():
    found = []
    for root, _, files in os.walk(STUB_SRC):
        found += [os.path.join(root, f) for f in files if f.endswith(".java")]
    return sorted(found)


def compile_stubs(classes_dir):
    sources = stub_sources()
    if not sources:
        sys.exit(f"no stub sources under {STUB_SRC}")
    subprocess.run([java8_tool("javac"), "-nowarn", "-source", "8", "-target", "8",
                    "-cp", BASE_JAR, "-d", classes_dir] + sources, check=True)


def stub_entries(classes_dir):
    entries = {}
    for root, _, files in os.walk(classes_dir):
        for f in files:
            path = os.path.join(root, f)
            entries[os.path.relpath(path, classes_dir).replace(os.sep, "/")] = path
    return entries


def replaced_outer_classes(entries):
    """A stub replaces every class file of its top-level class, nested ones included."""
    return {name.split("$")[0].removesuffix(".class") for name in entries}


def write_jar(out_jar, classes_dir):
    stubs = stub_entries(classes_dir)
    replaced = replaced_outer_classes(stubs)
    with zipfile.ZipFile(BASE_JAR) as base:
        kept = {info.filename: base.read(info.filename) for info in base.infolist()
                if not info.is_dir()
                and info.filename.split("$")[0].removesuffix(".class") not in replaced}
    for name, path in stubs.items():
        with open(path, "rb") as f:
            kept[name] = f.read()
    with zipfile.ZipFile(out_jar, "w", zipfile.ZIP_DEFLATED) as jar:
        for name in sorted(kept):
            info = zipfile.ZipInfo(name, FIXED_ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            jar.writestr(info, kept[name])
    return len(stubs)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: build-android-port.py OUT_DIR")
    out_dir = os.path.abspath(sys.argv[1])
    os.makedirs(out_dir, exist_ok=True)
    out_jar = os.path.join(out_dir, f"android-port-{VERSION}.jar")
    with tempfile.TemporaryDirectory() as classes_dir:
        compile_stubs(classes_dir)
        count = write_jar(out_jar, classes_dir)
    with open(os.path.join(out_dir, f"android-port-{VERSION}.pom"), "w") as pom:
        pom.write(POM.format(version=VERSION))
    print(f"[g55-android-port] {out_jar}: base + {count} stub class files")


if __name__ == "__main__":
    main()
