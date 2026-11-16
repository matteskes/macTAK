# The Homebrew packages macTAK builds with and ships, pinned in
# Brewfile.lock.json (issue #151). dev/deps/brew-pins.py fails a build when
# an installed version differs from its pin; `brew-pins.py --write` moves the
# pins on purpose (CONTRIBUTING.md, "Moving a Homebrew pin").
# supply-chain.yml checks this file equals the union of every workflow's
# `brew install` lines and that the lock matches what CI installs.

# --- loaded at run time: app/bundle.sh ships these in Contents/Frameworks
# (dev/deps/stage-runtime.py); `brew-pins.py --closure` fails on any library
# the engine loads from a package not listed here
# the engine
brew "geos"
brew "sqlite"            # one runtime for the process: engine, GDAL, PROJ, SpatiaLite
brew "minizip"
brew "libxml2"
brew "assimp"
brew "mdbtools"          # MS Access reader, with glib and its gettext and pcre2
brew "glib"
brew "gettext"
brew "pcre2"
# commo
brew "openssl@3"         # the process's one TLS library
brew "protobuf"
brew "abseil"            # protobuf's
# macTAK's own GDAL/PROJ/libspatialite (dev/deps/build-deps.sh) link these
brew "libtiff"           # PROJ's grid files, with jpeg-turbo, webp, xz and zstd
brew "jpeg-turbo"
brew "webp"
brew "xz"
brew "zstd"
brew "openjpeg"          # JP2OpenJPEG
brew "libkml"            # LIBKML, with uriparser
brew "uriparser"
brew "freexl"            # libspatialite, with librttopo
brew "librttopo"

# --- build and test only
brew "cmake"
brew "ninja"
brew "pkgconf"           # dev/deps, fetch-curl.sh, fetch-ngtcp2.sh
brew "swig"              # GDAL's Java bindings (dev/g2/fetch-gdal-java.sh)
brew "googletest"        # the engine's GTest canary and dev/g1/jni-tests
brew "nlohmann-json"     # header only: tinygltf's json.hpp
brew "gdal"              # the network tests' control ogrinfo and the fixture
                         # scripts' tools; not linked (dev/deps builds the engine's)
