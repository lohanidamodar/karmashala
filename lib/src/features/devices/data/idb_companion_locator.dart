import 'dart:io';

import 'package:path/path.dart' as p;

/// The pinned companion release. Bumping this means bumping the checksum in
/// `tool/vendor/fetch_idb_companion.sh` too — they are one decision.
const String kIdbCompanionVersion = 'v1.5.2';

/// Where a usable `idb_companion` was found, and how.
class IdbCompanionLocation {
  const IdbCompanionLocation({required this.executable, required this.source});

  final String executable;
  final IdbCompanionSource source;

  /// The sibling directory the companion resolves its guest binaries from.
  String get resourcesDirectory => p.join(p.dirname(executable), 'Resources');
}

/// Where a companion came from, which decides how much to trust its version.
enum IdbCompanionSource {
  /// Shipped inside this app — the pinned build, the expected case.
  bundled,

  /// The checkout's `macos/Vendor`, for a developer running from source.
  workingTree,

  /// The user's own, from Homebrew. Whatever version they have.
  path,
}

/// Finds the vendored `idb_companion`.
///
/// Three places, in order of how much is known about what is found:
///
/// 1. Inside the app bundle, where the build put the pinned release.
/// 2. `macos/Vendor/idb-companion` in the checkout, for anyone running
///    `flutter run` from source after `tool/vendor/fetch_idb_companion.sh`.
/// 3. `idb_companion` on `PATH` — someone's Homebrew install. Accepted because
///    refusing it would be worse than using it, but it is *not* the pinned
///    version and is recorded as such.
///
/// A companion is only ever accepted with its sibling `Resources/` beside it.
/// It resolves guest binaries as `dirname(realpath(argv[0])) + "/Resources"`,
/// and without them the accessibility path fails outright — no element tree —
/// while video and touch still work, which is the confusing half-broken state
/// this check exists to prevent.
class IdbCompanionLocator {
  IdbCompanionLocator({
    this.environment,
    this.resolvedExecutable,
    this.workingDirectory,
    bool? hostIsMacOs,
  }) : _hostIsMacOs = hostIsMacOs ?? Platform.isMacOS;

  /// Whether this host can have a companion at all. Injected so both answers
  /// stay reachable from a test on either OS.
  final bool _hostIsMacOs;

  /// Injected so the search is testable off macOS and without a real install.
  final Map<String, String>? environment;
  final String? resolvedExecutable;
  final String? workingDirectory;

  Map<String, String> get _env => environment ?? Platform.environment;
  String get _self => resolvedExecutable ?? Platform.resolvedExecutable;
  String get _cwd => workingDirectory ?? Directory.current.path;

  /// The first usable companion, or `null` when there is none.
  ///
  /// Never throws: on Windows, Linux, or an Intel Mac the honest answer is
  /// "there is none", and the pane degrades to what `simctl` alone can do.
  ///
  /// Off macOS this returns before touching the filesystem. The binary is not
  /// shipped there — it lives under `macos/`, which no Windows or Linux build
  /// reads, and it is deliberately **not** a Flutter asset, because assets are
  /// copied into every platform's bundle — so searching is guaranteed to find
  /// nothing, and stat-ing every entry of `PATH` to establish that is work no
  /// Windows user should pay for on every refresh.
  IdbCompanionLocation? locate() {
    if (!_hostIsMacOs) return null;
    for (final candidate in _candidates()) {
      final location = _accept(candidate.$1, candidate.$2);
      if (location != null) return location;
    }
    return null;
  }

  List<(String, IdbCompanionSource)> _candidates() {
    final candidates = <(String, IdbCompanionSource)>[];

    // Contents/MacOS/<app> → Contents/Resources/idb-companion/idb_companion
    final macOsDir = p.dirname(_self);
    candidates.add((
      p.join(
        p.dirname(macOsDir),
        'Resources',
        'idb-companion',
        'idb_companion',
      ),
      IdbCompanionSource.bundled,
    ));

    // A source checkout, from wherever `flutter run` was invoked.
    candidates.add((
      p.join(_cwd, 'macos', 'Vendor', 'idb-companion', 'idb_companion'),
      IdbCompanionSource.workingTree,
    ));

    for (final dir in (_env['PATH'] ?? '').split(':')) {
      if (dir.trim().isEmpty) continue;
      candidates.add((
        p.join(dir, 'idb_companion'),
        IdbCompanionSource.path,
      ));
    }
    return candidates;
  }

  IdbCompanionLocation? _accept(String path, IdbCompanionSource source) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      // Symlinks are followed because the companion itself follows them when
      // it resolves `Resources/`: a link in `/opt/homebrew/bin` points into a
      // Cellar directory, and that is where the guest binaries live.
      final real = file.resolveSymbolicLinksSync();
      if (!Directory(p.join(p.dirname(real), 'Resources')).existsSync()) {
        return null;
      }
      return IdbCompanionLocation(executable: real, source: source);
    } on FileSystemException {
      return null;
    }
  }
}

/// A path for the companion's gRPC domain socket.
///
/// Deliberately short, and deliberately not under the app's own support
/// directory. A Unix domain socket path is capped at 104 bytes on macOS, and
/// the application-support path alone is longer than that for many users —
/// measured: the companion refuses with
/// `NIOCore.SocketAddressError error 3` and never binds, having already
/// reported that it was starting.
String idbSocketPathFor(String udid, {String? temporaryDirectory}) {
  final dir = temporaryDirectory ?? Directory.systemTemp.path;
  // Enough of the udid to tell two simulators apart, short enough to fit.
  final short = udid.replaceAll('-', '').substring(0, 8).toLowerCase();
  return p.join(dir, 'idb-$short.sock');
}
