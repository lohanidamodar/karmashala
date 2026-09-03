import 'dart:io';

import 'package:path/path.dart' as p;

/// The pinned WebDriverAgent release. Bumping this means bumping the checksums
/// in `tool/vendor/fetch_wda.sh` too — they are one decision.
const String kWdaVersion = 'v16.12.0';

/// The runner's bundle id, as `simctl launch` and `terminate` name it.
const String kWdaBundleId = 'com.facebook.WebDriverAgentRunner.xctrunner';

/// Where a usable WebDriverAgent runner was found, and how.
class WdaLocation {
  const WdaLocation({
    required this.appPath,
    required this.source,
    this.version,
  });

  /// The `.app` bundle `simctl install` is given.
  final String appPath;

  final WdaSource source;

  /// What `tool/vendor/fetch_wda.sh` recorded beside the bundle, e.g.
  /// `v16.12.0 arm64`, or null when the marker is missing.
  ///
  /// Carried because the runner is a *built binary* pinned to one version, so
  /// "which one" is the first question when it will not attach to a simulator.
  final String? version;
}

enum WdaSource {
  /// Shipped inside this app — the pinned build, the expected case.
  bundled,

  /// The checkout's `macos/Vendor`, for a developer running from source.
  workingTree,
}

/// Finds the vendored `WebDriverAgentRunner-Runner.app`.
///
/// Two places, and no `PATH` fallback: WDA is not a command, it is an app
/// bundle installed *into* a simulator, so there is nothing on `PATH` to find.
///
/// Off macOS this returns before touching the filesystem. The bundle is not
/// shipped there — it lives under `macos/`, which no Windows or Linux build
/// reads, and it is deliberately not a Flutter asset, because assets are copied
/// into every platform's bundle.
class WdaLocator {
  WdaLocator({
    this.resolvedExecutable,
    this.workingDirectory,
    bool? hostIsMacOs,
  }) : _hostIsMacOs = hostIsMacOs ?? Platform.isMacOS;

  final String? resolvedExecutable;
  final String? workingDirectory;
  final bool _hostIsMacOs;

  String get _self => resolvedExecutable ?? Platform.resolvedExecutable;
  String get _cwd => workingDirectory ?? Directory.current.path;

  WdaLocation? locate() {
    if (!_hostIsMacOs) return null;
    const bundle = 'WebDriverAgentRunner-Runner.app';

    // Contents/MacOS/<app> → Contents/Resources/wda/<bundle>
    final macOsDir = p.dirname(_self);
    final candidates = <(String, WdaSource)>[
      (
        p.join(p.dirname(macOsDir), 'Resources', 'wda', bundle),
        WdaSource.bundled,
      ),
      (p.join(_cwd, 'macos', 'Vendor', 'wda', bundle), WdaSource.workingTree),
    ];

    for (final (path, source) in candidates) {
      try {
        if (Directory(path).existsSync()) {
          return WdaLocation(
            appPath: path,
            source: source,
            version: _versionBeside(path),
          );
        }
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  /// The `.wda-version` marker the fetch script writes next to the bundle.
  ///
  /// Absent is not an error: a bundle assembled by hand still works, it just
  /// cannot say which build it is.
  String? _versionBeside(String bundlePath) {
    try {
      final marker = File(p.join(p.dirname(bundlePath), '.wda-version'));
      if (!marker.existsSync()) return null;
      final text = marker.readAsStringSync().trim();
      return text.isEmpty ? null : text;
    } on FileSystemException {
      return null;
    }
  }
}
