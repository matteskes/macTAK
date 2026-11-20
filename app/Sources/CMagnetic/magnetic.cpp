// magnetic.cpp — the engine's util/GeomagneticField.cpp, less its config
// option and logging: the model is the file given to mactak_wmm_open.
//
// Kept from the engine on purpose:
// - getDayOfYear adds a leap year's extra day whatever the month, so in a
//   leap year January and February run a day late;
// - the decimal year is year + (dayOfYear - 1) / days;
// - the height goes in as kilometres above the ellipsoid, no geoid.

#include "magnetic.h"

#include <cstring>
#include <memory>
#include <mutex>
#include <string>

#include "formats/wmm/GeomagnetismHeader.h"

struct mactak_wmm {
    std::mutex mutex;
    MAGtype_Ellipsoid ellipsoid{};
    MAGtype_Geoid geoid{};
    MAGtype_MagneticModel *model = nullptr;
    MAGtype_MagneticModel *timeModel = nullptr;
    unsigned timeVersion = 0u;
};

namespace {
bool isLeapYear(unsigned year) {
    return !(year % 400u) || ((year % 100u) && !(year % 4u));
}
}

extern "C" mactak_wmm *mactak_wmm_open(const char *cof_path) {
    if (!cof_path)
        return nullptr;
    std::unique_ptr<mactak_wmm> wmm(new mactak_wmm());
    if (!MAG_SetDefaults(&wmm->ellipsoid, &wmm->geoid))
        return nullptr;
    MAGtype_MagneticModel *models[1] = {nullptr};
    MAGtype_MagneticModel **pmm = models;
    std::string path(cof_path);
    if (!MAG_robustReadMagModels(&path[0], &pmm, 1) || !models[0])
        return nullptr;
    wmm->model = models[0];
    return wmm.release();
}

extern "C" int mactak_wmm_declination(mactak_wmm *wmm, double lat, double lon, double hae,
                                      int year, int month, int day, double *declination) {
    if (!wmm || !declination)
        return -1;
    if (year < 1970 || month < 0 || month > 11 || day < 1 || day > 31)
        return -1;
    static const unsigned dayInYear[12] = {0u, 31u, 59u, 90u, 120u, 151u, 181u, 212u, 243u, 273u, 304u, 334u};
    unsigned dayOfYear = dayInYear[month] + static_cast<unsigned>(day);
    if (isLeapYear(static_cast<unsigned>(year)))
        dayOfYear += 1u;
    const double days = isLeapYear(static_cast<unsigned>(year)) ? 366.0 : 365.0;

    MAGtype_GeoMagneticElements elements;
    std::memset(&elements, 0, sizeof elements);
    {
        std::lock_guard<std::mutex> lock(wmm->mutex);
        const unsigned requested = (static_cast<unsigned>(year) << 8u) | dayOfYear;
        if (!wmm->timeModel || requested != wmm->timeVersion) {
            const int nMax = wmm->model->nMax > 0 ? wmm->model->nMax : 0;
            const int numTerms = (nMax + 1) * (nMax + 2) / 2;
            MAGtype_MagneticModel *timed = MAG_AllocateModelMemory(numTerms);
            if (!timed)
                return -1;
            MAGtype_Date date;
            date.DecimalYear = year + ((dayOfYear - 1u) / days);
            date.Year = year;
            date.Month = month;
            date.Day = day;
            if (!MAG_TimelyModifyMagneticModel(date, wmm->model, timed)) {
                MAG_FreeMagneticModelMemory(timed);
                return -1;
            }
            if (wmm->timeModel)
                MAG_FreeMagneticModelMemory(wmm->timeModel);
            wmm->timeModel = timed;
            wmm->timeVersion = requested;
        }
        MAGtype_CoordGeodetic geodetic;
        MAGtype_CoordSpherical spherical;
        std::memset(&geodetic, 0, sizeof geodetic);
        std::memset(&spherical, 0, sizeof spherical);
        geodetic.lambda = lon;
        geodetic.phi = lat;
        geodetic.HeightAboveEllipsoid = hae / 1000.0;   // metres to km
        geodetic.UseGeoid = 0;
        if (!MAG_GeodeticToSpherical(wmm->ellipsoid, geodetic, &spherical))
            return -1;
        if (!MAG_Geomag(wmm->ellipsoid, spherical, geodetic, wmm->timeModel, &elements))
            return -1;
        MAG_CalculateGridVariation(geodetic, &elements);   // the engine ignores its result too
    }
    *declination = elements.Decl;
    return 0;
}

extern "C" void mactak_wmm_close(mactak_wmm *wmm) {
    if (!wmm)
        return;
    if (wmm->timeModel)
        MAG_FreeMagneticModelMemory(wmm->timeModel);
    if (wmm->model)
        MAG_FreeMagneticModelMemory(wmm->model);
    delete wmm;
}
