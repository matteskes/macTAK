// magnetic.h — magnetic declination from the World Magnetic Model, as the
// engine's GeomagneticField computes it for ATAK 5.5 (G3.8a).
//
// The model is NOAA's GeomagnetismLibrary, vendored unchanged from the
// engine (formats/wmm, port/Platform.h), read from 5.5's coefficient file
// (takkernel/engine/src/main/res/raw/wmm_cof, WMMHR-2025). The shim around
// it ports util/GeomagneticField.cpp: the date as year, 0-based month and
// day; the model adjusted to that date once and kept; the declination in
// degrees, east positive. make test-rab-golden checks both the vendored
// files and the results against the engine.

#ifndef MACTAK_MAGNETIC_H
#define MACTAK_MAGNETIC_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mactak_wmm mactak_wmm;

/// Reads a WMM coefficient file; NULL when it can't be read.
mactak_wmm *mactak_wmm_open(const char *cof_path);

/// The declination at lat, lon (degrees) and hae (metres) on the given day
/// (month 0-11, as java.util.Calendar). 0 on success; nonzero for a date
/// the engine refuses (before 1970, month > 11, day outside 1-31).
int mactak_wmm_declination(mactak_wmm *wmm, double lat, double lon, double hae,
                           int year, int month, int day, double *declination);

void mactak_wmm_close(mactak_wmm *wmm);

#ifdef __cplusplus
}
#endif

#endif
