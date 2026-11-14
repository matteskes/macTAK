# Union of the brew packages every workflow installs: ci.yml's engine + comms
# sets, plus spike-55.yml's 5.5-engine extras (ninja, mdbtools, glib, assimp).
# Kept in lockfile form: supply-chain.yml runs `brew bundle check` against
# Brewfile.lock.json and fails when this file and the committed lock drift.
brew "cmake"
brew "rsync"
brew "proj"
brew "geos"
brew "gdal"
brew "libspatialite"
brew "minizip"
brew "nlohmann-json"
brew "laszip"
brew "googletest"
brew "openssl@3"
brew "libxml2"
brew "protobuf"
brew "swig"
brew "ninja"
brew "mdbtools"
brew "glib"
brew "assimp"
# macTAK's own GDAL/PROJ/libspatialite (dev/deps/build-deps.sh) link these:
# sqlite (one runtime for the process), libtiff (PROJ's grids), openjpeg
# (JP2OpenJPEG), libkml + uriparser (LIBKML), freexl + librttopo
# (libspatialite); pkgconf finds them, and openssl@3 for fetch-curl.sh.
brew "sqlite"
brew "libtiff"
brew "openjpeg"
brew "libkml"
brew "uriparser"
brew "freexl"
brew "librttopo"
brew "pkgconf"
