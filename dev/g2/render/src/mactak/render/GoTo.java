package mactak.render;

import android.graphics.PointF;
import com.atakmap.coremap.maps.coords.GeoBounds;
import com.atakmap.coremap.maps.coords.GeoCalculations;
import com.atakmap.coremap.maps.coords.GeoPoint;
import com.atakmap.map.Globe;
import com.atakmap.map.MapRenderer2;
import com.atakmap.map.MapRenderer3;
import com.atakmap.map.MapSceneModel;
import com.atakmap.map.elevation.ElevationManager;
import com.atakmap.map.opengl.GLMapView;
import com.atakmap.map.projection.MapProjectionDisplayModel;
import com.atakmap.math.MathUtils;
import com.atakmap.math.PointD;
import com.atakmap.math.Rectangle;

/**
 * The Overlay Manager's GoTo (G3.11b), ported from 5.5 as it moves the map:
 * MapTouchController.goTo scales the map to fit the item
 * (ATAKUtilities.scaleToFit: a marker into 1/18th of the view, a shape into
 * all of it), then a marker is focused (FocusBroadcastReceiver's FOCUS with
 * useTightZoom: a one-shot lookAt on it, zoomed to at least
 * FOCUS_MAP_SCALE_VALUE). What MapView supplies there is read off the
 * renderer here: its scene model (tMapSceneModel), its width and height,
 * its centre's longitude, its tilt, continuous scroll and its maximum tilt
 * (MapView.getMaxMapTilt: 89 degrees with the perspective camera, else 75).
 *
 * <p>Left out: the focus that follows the marker while it moves (FOCUS's
 * point-changed listener and camera lock), which is 5.5's map focus, not
 * the Overlay Manager's. Render thread only.
 */
final class GoTo {
    private GoTo() { }

    /** FocusBroadcastReceiver.FOCUS_MAP_SCALE_VALUE. */
    private static final double FOCUS_MAP_SCALE_VALUE = 1.0d / 197219.1758d;

    /**
     * MapTouchController.goTo's camera: {@code latLons} is the item's points
     * (one for a point item), {@code altitude} its point's, or the highest
     * of a shape's (NaN when none is known); {@code marker} a Marker (fit
     * into 1/18th of the view), {@code point} a PointMapItem (focused).
     */
    static void goTo(GLMapView view, double dpi, double[] latLons, double altitude, boolean marker, boolean point) {
        final GeoPoint[] points = new GeoPoint[latLons.length / 2];
        for (int i = 0; i < points.length; i++)
            points[i] = point && !Double.isNaN(altitude)
                    ? new GeoPoint(latLons[2 * i], latLons[2 * i + 1], altitude)
                    : new GeoPoint(latLons[2 * i], latLons[2 * i + 1]);
        final MapSceneModel sm = view.getMapSceneModel(false, MapRenderer2.DisplayOrigin.UpperLeft);
        final int scale = marker ? 18 : 1;
        scaleToFit(view, points, altitude, sm.width / scale, sm.height / scale);
        if (point) focus(view, dpi, points[0]);
    }

    /** ATAKUtilities.scaleToFit(MapView, GeoPoint[], double, int, int). */
    static boolean scaleToFit(GLMapView mv, GeoPoint[] points, double altitude, int widthPad, int heightPad) {
        if (points.length == 0)
            return false;

        // get the extremes in pixel-size so we can zoom to that size
        int[] e = GeoCalculations.findExtremes(points, 0, points.length, mv.continuousScrollEnabled);
        if (e.length < 4)
            return false;

        GeoPoint north = points[e[1]], south = points[e[3]];
        GeoPoint west = points[e[0]], east = points[e[2]];
        double minLat = south.getLatitude(), maxLat = north.getLatitude();
        double minLng = west.getLongitude(), maxLng = east.getLongitude();
        boolean crossesIDL = mv.continuousScrollEnabled
                && Math.abs(maxLng - minLng) > 180 && maxLng <= 180
                && minLng >= -180;
        if (crossesIDL)
            minLng = west.getLongitude() - 360;
        GeoBounds bounds = new GeoBounds(minLat, minLng, maxLat, maxLng);

        return scaleToFit(mv, bounds, altitude, widthPad, heightPad);
    }

    /** ATAKUtilities.scaleToFit(MapView, GeoBounds, double, int, int), deprecated calls and all. */
    @SuppressWarnings("deprecation")
    static boolean scaleToFit(GLMapView mv, GeoBounds bounds, double altitude, int widthPad, int heightPad) {
        double minLat = bounds.getSouth();
        double maxLat = bounds.getNorth();
        double minLng = bounds.getWest();
        double maxLng = bounds.getEast();
        GeoPoint center = bounds.getCenter(null);
        double cLat = center.getLatitude();
        double cLng = center.getLongitude();

        MapSceneModel scaleToModel = mv.getMapSceneModel(false, MapRenderer2.DisplayOrigin.UpperLeft);
        // MapView's own scene model and centre, as the frame last drew them
        final MapSceneModel tMapSceneModel = mv.getMapSceneModel(false, MapRenderer2.DisplayOrigin.UpperLeft);
        final double mvLongitude = tMapSceneModel.mapProjection.inverse(tMapSceneModel.camera.target, null)
                .getLongitude();

        // IDL corrections
        if (bounds.crossesIDL()) {
            if (cLng < 0) {
                minLng = bounds.getEast() - 360;
                maxLng = bounds.getWest();
            } else {
                minLng = bounds.getEast();
                maxLng = bounds.getWest() + 360;
            }
        }
        double unwrap = 0;
        if (minLng < -180 || maxLng > 180)
            unwrap = mvLongitude > 0 ? 360 : -360;

        final double localAlt = ElevationManager.getElevation(
                cLat, GeoCalculations.wrapLongitude(cLng), null);

        if (!GeoPoint.isAltitudeValid(altitude))
            altitude = localAlt;
        else if (!Double.isNaN(localAlt) && altitude < localAlt)
            altitude = localAlt;

        final GeoPoint panTo = new GeoPoint(
                cLat, GeoCalculations.wrapLongitude(cLng),
                Double.isNaN(altitude) ? 0d : altitude);

        scaleToModel.set(
                scaleToModel.dpi,
                scaleToModel.width, scaleToModel.height,
                scaleToModel.mapProjection,
                panTo,
                scaleToModel.focusx, scaleToModel.focusy,
                scaleToModel.camera.azimuth,
                90d + scaleToModel.camera.elevation,
                scaleToModel.gsd,
                true);

        // the perspective camera has additional effective zoom based on the
        // AGL -- we will need to adjust the scale factor to account for this.
        double zoomFactor = 1d;
        if (!scaleToModel.camera.perspective) {
            double spread = 0.0;
            if (Double.compare(minLat, maxLat) == 0
                    || Double.compare(minLng, maxLng) == 0)
                spread = 0.0001d;

            if (minLng < -180 || maxLng > 180)
                unwrap = mvLongitude > 0 ? 360 : -360;

            PointF northWest = forward(mv, tMapSceneModel, new GeoPoint(maxLat + spread, minLng - spread), unwrap);
            PointF southEast = forward(mv, tMapSceneModel, new GeoPoint(minLat - spread, maxLng + spread), unwrap);

            double padding = widthPad / 4d;
            // 5.5's int -= double: truncated
            widthPad = (int) (widthPad - padding);
            heightPad = (int) (heightPad - padding);

            double modelWidth = Math.abs(northWest.x - southEast.x);
            double modelHeight = Math.abs(northWest.y - southEast.y);

            zoomFactor = widthPad / modelWidth;
            if (zoomFactor * modelHeight > heightPad)
                zoomFactor = heightPad / modelHeight;
        } else {
            // compute bounding sphere, set a reasonable minimum limit
            final double radius = MathUtils.max(
                    GeoCalculations.distanceTo(
                            new GeoPoint(maxLat, (minLng + maxLng) / 2d),
                            new GeoPoint(maxLat, (minLng + maxLng) / 2d)) / 2d,
                    GeoCalculations.distanceTo(
                            new GeoPoint((minLat + maxLat) / 2d, minLng),
                            new GeoPoint((minLat + maxLat) / 2d, maxLng)) / 2d,
                    GeoCalculations.distanceTo(new GeoPoint(maxLat, minLng),
                            new GeoPoint(minLat, maxLng)) / 2d,
                    10d // minimum of 10m radius for zoom purposes
            );

            double padding = widthPad / 4d;
            // 5.5's int -= double: truncated
            widthPad = (int) (widthPad - padding);
            heightPad = (int) (heightPad - padding);

            // compute the dimension, in pixels, to capture the object radius
            final double pixelsAtD = Math.min(heightPad, widthPad);
            // compute the local GSD of the object
            final double gsdAtD = radius / (pixelsAtD / 2d);

            // compute camera range to centroid at target GSD. Adjust by altitude to account for AGL relative scaling.
            final double camRange = MapSceneModel.range(gsdAtD,
                    scaleToModel.camera.fov, scaleToModel.height)
                    + panTo.getAltitude();
            // compute GSD based on AGL adjusted range
            final double gsd = MapSceneModel.gsd(camRange,
                    scaleToModel.camera.fov, scaleToModel.height);

            // create a model such that the major-radius adheres to the minor dimension
            scaleToModel.set(
                    scaleToModel.dpi,
                    scaleToModel.width, scaleToModel.height,
                    scaleToModel.mapProjection,
                    scaleToModel.mapProjection
                            .inverse(scaleToModel.camera.target, null),
                    scaleToModel.focusx, scaleToModel.focusy,
                    scaleToModel.camera.azimuth,
                    90d + scaleToModel.camera.elevation,
                    gsd,
                    true);

            // for larger objects, try to closely fit the AABB against the
            // padded dimensions. small objects will zoom in too far.
            if (radius > 10d) {
                double spread = 0.0;
                if (Double.compare(minLat, maxLat) == 0
                        || Double.compare(minLng, maxLng) == 0)
                    spread = 0.0001d;

                // shift longitude for IDL for flat projection
                if (scaleToModel.mapProjection
                        .getSpatialReferenceID() == 4326) {
                    if (Math.abs(panTo.getLongitude() - minLng) > 180d)
                        minLng += (panTo.getLongitude() < 0d) ? -360d : 360d;
                    if (Math.abs(panTo.getLongitude() - maxLng) > 180d)
                        maxLng += (panTo.getLongitude() < 0d) ? -360d : 360d;
                }

                PointD northWest = new PointD(0d, 0d, 0d);
                scaleToModel.forward(
                        new GeoPoint(maxLat + spread, minLng - spread,
                                ElevationManager.getElevation(maxLat + spread,
                                        minLng - spread, null)),
                        northWest);
                PointD northEast = new PointD(0d, 0d, 0d);
                scaleToModel.forward(
                        new GeoPoint(maxLat + spread, minLng + spread,
                                ElevationManager.getElevation(maxLat + spread,
                                        minLng + spread, null)),
                        northEast);
                PointD southEast = new PointD(0d, 0d, 0d);
                scaleToModel.forward(
                        new GeoPoint(minLat - spread, minLng + spread,
                                ElevationManager.getElevation(maxLat - spread,
                                        minLng + spread, null)),
                        southEast);
                PointD southWest = new PointD(0d, 0d, 0d);
                scaleToModel.forward(
                        new GeoPoint(minLat - spread, maxLng - spread,
                                ElevationManager.getElevation(minLat - spread,
                                        maxLng - spread, null)),
                        southWest);

                // establish the plane that the camera will zoom relative to
                final double zoomPlaneZ = MathUtils.min(northWest.z,
                        northEast.z, southEast.z, southWest.z);

                PointD ss_ul = new PointD(
                        MathUtils.min(northWest.x, northEast.x, southEast.x,
                                southWest.x),
                        MathUtils.min(northWest.y, northEast.y, southEast.y,
                                southWest.y),
                        zoomPlaneZ);
                PointD ss_ll = new PointD(
                        MathUtils.min(northWest.x, northEast.x, southEast.x,
                                southWest.x),
                        MathUtils.max(northWest.y, northEast.y, southEast.y,
                                southWest.y),
                        zoomPlaneZ);
                PointD ss_lr = new PointD(
                        MathUtils.max(northWest.x, northEast.x, southEast.x,
                                southWest.x),
                        MathUtils.max(northWest.y, northEast.y, southEast.y,
                                southWest.y),
                        zoomPlaneZ);

                // transform screenspace corners into WCS
                PointD wcs_ul = new PointD(0d, 0d, 0d);
                PointD wcs_ll = new PointD(0d, 0d, 0d);
                PointD wcs_lr = new PointD(0d, 0d, 0d);
                PointD wcs_c = new PointD(0d, 0d, 0d);

                scaleToModel.inverse.transform(ss_ul, wcs_ul);
                scaleToModel.inverse.transform(ss_ll, wcs_ll);
                scaleToModel.inverse.transform(ss_lr, wcs_lr);

                // compute target point on plane
                scaleToModel.inverse.transform(new PointD(scaleToModel.focusx,
                        scaleToModel.focusy, zoomPlaneZ), wcs_c);

                // compute vertical and horizontal axes on zoom-to plane in WCS
                final double verticalAxis = wcs_distance(wcs_ul, wcs_ll,
                        scaleToModel.displayModel);
                final double horizontalAxis = wcs_distance(wcs_lr, wcs_ll,
                        scaleToModel.displayModel);

                // compute vertical and horizontal GSDs on zoom plane
                final double gsdVertical = verticalAxis / heightPad;
                final double gsdHorizontal = horizontalAxis / widthPad;
                final double vpixelsHgsd = verticalAxis / gsdHorizontal;
                final double hpixelsVgsd = horizontalAxis / gsdVertical;

                // select GSD that will most closely correspond to padded width or
                // height
                final double gsdAtZoomPlane;
                if (vpixelsHgsd > heightPad)
                    gsdAtZoomPlane = gsdVertical;
                else if (hpixelsVgsd > widthPad)
                    gsdAtZoomPlane = gsdHorizontal;
                else
                    gsdAtZoomPlane = Math.min(gsdVertical, gsdHorizontal);

                // compute the camera range from the zoom plane
                final double rangeAtZoomPlane = MapSceneModel.range(
                        gsdAtZoomPlane, scaleToModel.camera.fov,
                        scaleToModel.height);

                // compute camera location
                double dx = (scaleToModel.camera.location.x - wcs_c.x)
                        * scaleToModel.displayModel.projectionXToNominalMeters;
                double dy = (scaleToModel.camera.location.y - wcs_c.y)
                        * scaleToModel.displayModel.projectionYToNominalMeters;
                double dz = (scaleToModel.camera.location.z - wcs_c.z)
                        * scaleToModel.displayModel.projectionZToNominalMeters;
                final double m = MathUtils.distance(dx, dy, dz, 0d, 0d, 0d);
                dx /= m;
                dy /= m;
                dz /= m;

                PointD camera = new PointD(
                        wcs_c.x + (dx * rangeAtZoomPlane)
                                / scaleToModel.displayModel.projectionXToNominalMeters,
                        wcs_c.y + (dy * rangeAtZoomPlane)
                                / scaleToModel.displayModel.projectionYToNominalMeters,
                        wcs_c.z + (dz * rangeAtZoomPlane)
                                / scaleToModel.displayModel.projectionZToNominalMeters);

                final double rangeToTarget = wcs_distance(camera,
                        scaleToModel.camera.target, scaleToModel.displayModel);

                scaleToModel.set(
                        scaleToModel.dpi,
                        scaleToModel.width, scaleToModel.height,
                        scaleToModel.mapProjection,
                        panTo,
                        scaleToModel.focusx, scaleToModel.focusy,
                        scaleToModel.camera.azimuth,
                        90d + scaleToModel.camera.elevation,
                        MapSceneModel.gsd(rangeToTarget + panTo.getAltitude(),
                                scaleToModel.camera.fov, scaleToModel.height),
                        true);
            }
            // zoom is already adjusted
        }

        // Clamp tilt to max at new zoom level (MapView.getMaxMapTilt(scale)
        // is its maximum tilt, whatever the scale)
        double maxTilt = maxMapTilt();
        if (90d + tMapSceneModel.camera.elevation > maxTilt) {
            scaleToModel.set(
                    scaleToModel.dpi,
                    scaleToModel.width, scaleToModel.height,
                    scaleToModel.mapProjection,
                    scaleToModel.mapProjection
                            .inverse(scaleToModel.camera.target, null),
                    scaleToModel.focusx, scaleToModel.focusy,
                    scaleToModel.camera.azimuth,
                    maxTilt,
                    scaleToModel.gsd,
                    true);
        }

        // Zoom to area
        scaleToModel.set(
                scaleToModel.dpi,
                scaleToModel.width, scaleToModel.height,
                scaleToModel.mapProjection,
                scaleToModel.mapProjection.inverse(scaleToModel.camera.target,
                        null),
                scaleToModel.focusx, scaleToModel.focusy,
                scaleToModel.camera.azimuth,
                90d + scaleToModel.camera.elevation,
                scaleToModel.gsd / zoomFactor,
                true);

        mv.lookAt(
                scaleToModel.mapProjection.inverse(scaleToModel.camera.target,
                        null),
                scaleToModel.gsd,
                scaleToModel.camera.azimuth,
                90d + scaleToModel.camera.elevation,
                MapRenderer3.CameraCollision.Ignore,
                true);

        return true;
    }

    /**
     * FocusBroadcastReceiver._setFocusPoint(point, useTightZoom true), once:
     * pan to the point (MapView.getRenderElevationAdjustedPoint), zoomed to
     * at least FOCUS_MAP_SCALE_VALUE, the tilt cleared when it is off screen.
     */
    @SuppressWarnings("deprecation")
    static void focus(GLMapView mv, double dpi, GeoPoint point) {
        GeoPoint panTo = renderElevationAdjustedPoint(mv, point, Double.NaN);

        final MapSceneModel sm = mv.getMapSceneModel(false, MapRenderer2.DisplayOrigin.UpperLeft);

        double tilt = 90d + sm.camera.elevation;
        // if the map is tilted and the point is in view, do a relative
        // pan/zoom
        PointF focusXY = forward(mv, sm, panTo, 0);
        if (90d + sm.camera.elevation > 0d &&
                !Rectangle.contains(0, 0, sm.width, sm.height, focusXY.x, focusXY.y)) {
            // clear the tilt
            tilt = 0d;
        }

        // pan/zoom
        double gsd = sm.gsd;
        if (Globe.getMapScale(dpi, gsd) < FOCUS_MAP_SCALE_VALUE)
            gsd = Globe.getMapResolution(dpi, FOCUS_MAP_SCALE_VALUE);

        // ensure we have adequate camera range
        final double maxGsd = maximumFocusResolution(panTo,
                ElevationManager.getElevation(panTo.getLatitude(), panTo.getLongitude(), null),
                sm.camera.fov, sm.height);
        if (gsd < maxGsd)
            gsd = maxGsd;

        mv.lookAt(panTo, gsd, sm.camera.azimuth, tilt, true);
    }

    /** ATAKUtilities.getMaximumFocusResolution(GeoPoint, double, double, int). */
    private static double maximumFocusResolution(GeoPoint location, double localElevation, double vfov, int heightPx) {
        final double alt = location.getAltitude();
        if (Double.isNaN(alt))
            return 0d;
        if (location.getAltitudeReference() == GeoPoint.AltitudeReference.AGL && alt <= 0d)
            return 0d;
        if (alt <= localElevation)
            return 0d;
        final double minOffset = 25d;
        return MapSceneModel.gsd(alt + minOffset, vfov, heightPx);
    }

    /** AtakMapView.getRenderElevationAdjustedPoint. */
    @SuppressWarnings("deprecation")
    private static GeoPoint renderElevationAdjustedPoint(GLMapView glview, GeoPoint point, double elevOffset) {
        double alt = point.getAltitude();
        if (!point.isAltitudeValid())
            alt = glview.getTerrainMeshElevation(point.getLatitude(), point.getLongitude());
        double el = GeoPoint.isAltitudeValid(alt) ? alt : 0d;
        if (!Double.isNaN(elevOffset))
            el += elevOffset;
        return new GeoPoint(point.getLatitude(), point.getLongitude(),
                (el + GLMapView.elevationOffset) * glview.getElevationExaggerationFactor());
    }

    /** AtakMapView.forward(GeoPoint, double). */
    private static PointF forward(GLMapView mv, MapSceneModel tMapSceneModel, GeoPoint g, double unwrap) {
        if (mv.continuousScrollEnabled && (unwrap < 0 && g.getLongitude() > 0
                || unwrap > 0 && g.getLongitude() < 0))
            g = new GeoPoint(g.getLatitude(), g.getLongitude() + unwrap);
        return tMapSceneModel.forward(g, (PointF) null);
    }

    /** MapView.getMaxMapTilt(). */
    private static double maxMapTilt() {
        return MapSceneModel.isPerspectiveCameraEnabled() ? 89d : 75d;
    }

    /** ATAKUtilities.wcs_distance. */
    private static double wcs_distance(PointD a, PointD b, MapProjectionDisplayModel displayModel) {
        return MathUtils.distance(
                a.x * displayModel.projectionXToNominalMeters,
                a.y * displayModel.projectionYToNominalMeters,
                a.z * displayModel.projectionZToNominalMeters,
                b.x * displayModel.projectionXToNominalMeters,
                b.y * displayModel.projectionYToNominalMeters,
                b.z * displayModel.projectionZToNominalMeters);
    }
}
