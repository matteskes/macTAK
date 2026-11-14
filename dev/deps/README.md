# macTAK's own GDAL, PROJ and libspatialite

`build-deps.sh` builds GDAL, PROJ and libspatialite from the source tarballs
pinned in `deps.lock` into `dev/deps/dist`. `dev/g1/build-native.sh` runs it
first, and the engine, the JNI glue and GDAL's Java bindings
(`dev/g2/fetch-gdal-java.sh`) link the result. It's a no-op when
`dist/BUILD-STAMP` matches the pins and the script; CI caches `dist` on the
same inputs.

## Why not Homebrew's GDAL

The process should carry one TLS stack, OpenSSL 3. Homebrew's GDAL bottle
links **OpenSSL 4** directly and through libpq, thrift and Homebrew's curl,
and pulls in about 85 packages and 196 MB for formats macTAK refuses to open
(PDF, NetCDF, HDF5, Arrow, PostgreSQL, HEIF/AV1). Its version also moves with
`brew upgrade`.

This build:

- **has no curl and no TLS code at all.** GDAL can't fetch a URL, so
  `keepOffline()` (`dev/g1/jni-extra/mactak_gdal.cpp`) is a second line of
  defence, not the only one.
- **builds only the drivers macTAK allows** (the `keepOffline()` allowlist),
  plus the ones that come from the same sources; `gdal-drivers.txt` lists
  them all.
- **keeps one PROJ and one sqlite in the process.** libspatialite is rebuilt
  against this PROJ; GDAL uses its internal libgeotiff, because Homebrew's
  links Homebrew's PROJ. Everything links Homebrew's sqlite by its opt path,
  as the engine does.
- **pins the version.** A GDAL bump is one line in `deps.lock`.

The libraries it still takes from Homebrew have no TLS: sqlite, geos,
libtiff, openjpeg, libkml with minizip and uriparser, freexl and librttopo.

| Library | Built with | Left out |
|---|---|---|
| PROJ | libtiff (grid files) | curl, network grids, apps |
| GDAL | the allowlisted drivers; internal libtiff, libgeotiff, libjpeg, libpng, giflib, json-c | curl, every other driver and library, GNM, apps, Python |
| libspatialite | PROJ above, geos, librttopo, freexl, minizip | libxml2 (its XmlBLOB functions and WFS client, which the engine doesn't use) |

The runtime needs only PROJ's `proj.db`, not Homebrew's 775 MB grid package:
the engine adds the geoid itself (`GdalElevationChunk`).

## The guards

`make check-deps` (`check.sh`), in CI's native and render jobs:

- **`check-gdal-drivers.sh`:** the built GDAL registers exactly the drivers in
  `gdal-drivers.txt`.
- **`check-closure.py`:** walks every library the engine, JNI glue, commo and
  GDAL's Java bindings load, resolving `@rpath` as dyld does. It fails on
  OpenSSL 4, Homebrew's curl or libpq, Homebrew's GDAL, PROJ or
  libspatialite, or a second copy of libgdal or libproj.

## Bumping a version

1. Edit the line in `deps.lock`: version, the tarball's SHA-256 and URL.
2. `make deps`, then `MACTAK_GLES=angle bash dev/g1/build-native.sh` and
   `make gdal-java`.
3. `make check-deps`. If the driver list changed, decide whether the new
   driver belongs: update `gdal-drivers.txt`, and for a driver macTAK
   should open, `keepOffline()`'s allowlist and its network probe
   (`dev/g1/NOTES.md` §G1.19, §G1.26).
4. The usual suites: `make test-render`, `make test-gdal-network`,
   `make test-gdal-projection`, `dev/g1/headless/test/layer.sh`.

## Where the libraries live

They stay in `dev/deps/dist`: the engine and the Java bindings both find them
through an rpath to `dev/deps/dist/lib`, so the process loads one libgdal. A
copy next to the engine would be a second one. Bundling them into an app,
with every install name relative, is the next step (#152).
