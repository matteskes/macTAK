// LaunchConfig.swift — where the engine is: the JVM classpath and options,
// the engine's natives, ANGLE, and the data the map opens with.
//
// app/bundle.sh writes it as Contents/Resources/engine/launch.json. Paths
// without a leading "/" are relative to that engine directory, and
// "${ENGINE}" inside a JVM option or an environment value is replaced by it.
// `environment` is set in the process before the JVM starts: PROJ and GDAL
// read PROJ_DATA and GDAL_DATA from it, so the bundle's own data is used
// rather than the build machine's (issue #152). MACTAK_LAUNCH=FILE points
// at another launch.json (its directory is then the engine dir).

import Foundation
import MacTAKCore

struct LaunchConfig: Decodable {
    var classpath: [String]
    var libs: [String]
    var egl: String
    var gles: String
    var jvmOptions: [String]
    var environment: [String: String] = [:]
    var layers: [String] = []
    var basemaps: [String] = []
    var elevations: [String] = []

    /// The engine directory the relative paths resolve against.
    private(set) var engineDir = URL(fileURLWithPath: "/")

    private enum CodingKeys: String, CodingKey {
        case classpath, libs, egl, gles, jvmOptions, environment, layers, basemaps, elevations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        classpath = try c.decode([String].self, forKey: .classpath)
        libs = try c.decode([String].self, forKey: .libs)
        egl = try c.decode(String.self, forKey: .egl)
        gles = try c.decode(String.self, forKey: .gles)
        jvmOptions = try c.decodeIfPresent([String].self, forKey: .jvmOptions) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        layers = try c.decodeIfPresent([String].self, forKey: .layers) ?? []
        basemaps = try c.decodeIfPresent([String].self, forKey: .basemaps) ?? []
        elevations = try c.decodeIfPresent([String].self, forKey: .elevations) ?? []
    }

    static func load() throws -> LaunchConfig {
        let file: URL
        if let env = ProcessInfo.processInfo.environment["MACTAK_LAUNCH"], !env.isEmpty {
            file = URL(fileURLWithPath: env)
        } else if let res = Bundle.main.resourceURL {
            file = res.appendingPathComponent("engine/launch.json")
        } else {
            throw JNIError("no launch.json: not in an app bundle and MACTAK_LAUNCH is unset")
        }
        guard let data = FileManager.default.contents(atPath: file.path) else {
            throw JNIError("no launch.json at \(file.path) (build the app with `make app`)")
        }
        var config = try JSONDecoder().decode(LaunchConfig.self, from: data)
        config.engineDir = file.deletingLastPathComponent()
        return config
    }

    func path(_ p: String) -> String {
        p.hasPrefix("/") ? p : engineDir.appendingPathComponent(p).path
    }

    var resolvedClasspath: String { classpath.map(path).joined(separator: ":") }

    var resolvedJvmOptions: [String] {
        jvmOptions.map(expand)
    }

    private func expand(_ s: String) -> String {
        s.replacingOccurrences(of: "${ENGINE}", with: engineDir.path)
    }

    /// Sets `environment` in this process, before the JVM and the engine's
    /// natives start. A variable already set by the caller wins.
    func applyEnvironment() {
        for (name, value) in environment {
            setenv(name, expand(value), 0)
        }
    }

    /// The map's configuration for the app: no gates, no scripted phase.
    var mapConfig: MapConfig {
        var c = MapConfig()
        c.libs = libs.map(path)
        c.egl = path(egl)
        c.gles = path(gles)
        c.layers = layers.map(path)
        c.basemaps = basemaps.map(path)
        c.elevations = elevations.map(path)
        c.frames = 1
        c.settleMs = 0
        c.contentGate = false
        return c
    }
}
