// geoid-oracle.cpp — the engine's own geoid, outside the engine (G3.6a).
//
// ATAK 5.5 configures no `egm96-file`, so EGM96.getOffset always falls
// through ElevationManager_getGeoidHeight to the WMM grid compiled into the
// engine (formats/wmm/EGM9615.h, 721 x 1441 floats at 15') and
// MAG_GetGeoidHeight's bilinear interpolation. This program is built from
// those two files, unchanged, at the pin (dev/g3/test/coord-golden.sh):
//
//   geoid-oracle grid OUT   writes the grid as the Swift port loads it:
//                           little-endian float32, row 0 at 90N, column 0
//                           at 0E (app/Resources/egm96-15.grid)
//   geoid-oracle heights    reads "lat<TAB>lon" lines, writes
//                           "lat<TAB>lon<TAB>offset" (or "!invalid")
//
// The WMM code is public domain (GeomagnetismLibrary.cpp's header).

#include <cmath>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>

#include "formats/wmm/GeomagnetismHeader.h"
#include "formats/wmm/EGM9615.h"

namespace {

// ElevationManager_getGeoidHeight's checks and longitude wrap, then its WMM
// fall-through (ElevationManager.cpp at the pin).
bool geoidHeight(double *height, double latitude, double longitude, MAGtype_Geoid *geoid) {
    if (std::isnan(latitude) || std::isnan(longitude)) return false;
    if (latitude < -90.0 || latitude > 90.0) return false;
    if (longitude < -180.0) longitude += 360.0;
    else if (longitude > 180.0) longitude -= 360.0;
    return MAG_GetGeoidHeight(latitude, longitude, height, geoid) == TRUE;
}

int writeGrid(const char *path, const MAGtype_Geoid &geoid) {
    FILE *out = std::fopen(path, "wb");
    if (!out) { std::perror(path); return 1; }
    const size_t n = static_cast<size_t>(geoid.NumbGeoidElevs);
    if (sizeof(GeoidHeightBuffer) / sizeof(GeoidHeightBuffer[0]) != n) {
        std::fprintf(stderr, "geoid-oracle: EGM9615.h has %zu values, MAG_SetDefaults expects %zu\n",
                     sizeof(GeoidHeightBuffer) / sizeof(GeoidHeightBuffer[0]), n);
        return 1;
    }
    for (size_t i = 0; i < n; i++) {
        uint32_t bits;
        std::memcpy(&bits, &GeoidHeightBuffer[i], sizeof bits);
        unsigned char le[4] = {static_cast<unsigned char>(bits), static_cast<unsigned char>(bits >> 8),
                               static_cast<unsigned char>(bits >> 16), static_cast<unsigned char>(bits >> 24)};
        if (std::fwrite(le, 1, 4, out) != 4) { std::perror(path); return 1; }
    }
    return std::fclose(out) == 0 ? 0 : 1;
}

int writeHeights(MAGtype_Geoid *geoid) {
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty() || line[0] == '#') continue;
        const size_t tab = line.find('\t');
        if (tab == std::string::npos) { std::fprintf(stderr, "geoid-oracle: not lat<TAB>lon: %s\n", line.c_str()); return 1; }
        const double lat = std::stod(line.substr(0, tab)), lon = std::stod(line.substr(tab + 1));
        double height;
        if (geoidHeight(&height, lat, lon, geoid))
            std::printf("%s\t%.9f\n", line.c_str(), height);
        else
            std::printf("%s\t!invalid\n", line.c_str());
    }
    return 0;
}

}  // namespace

int main(int argc, char **argv) {
    MAGtype_Ellipsoid ellipsoid;
    MAGtype_Geoid geoid;
    MAG_SetDefaults(&ellipsoid, &geoid);   // as ElevationManager's GeoMag does
    geoid.GeoidHeightBuffer = GeoidHeightBuffer;
    geoid.Geoid_Initialized = 1;

    if (argc == 3 && std::strcmp(argv[1], "grid") == 0) return writeGrid(argv[2], geoid);
    if (argc == 2 && std::strcmp(argv[1], "heights") == 0) return writeHeights(&geoid);
    std::fprintf(stderr, "usage: geoid-oracle grid OUT | geoid-oracle heights < points\n");
    return 2;
}
