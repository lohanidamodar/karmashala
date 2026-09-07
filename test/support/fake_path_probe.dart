import 'package:karmashala/src/core/paths/path_probe.dart';

/// A described disk: which files exist, which components are reparse points and
/// where they lead, and which paths the OS refuses to answer about.
///
/// Nothing here touches a real filesystem, so a test can describe the owner's
/// broken junction chain on any host and the suite never depends on whether
/// Codex happens to be installed on the machine running it.
class FakePathProbe implements PathProbe {
  FakePathProbe({
    Set<String> files = const {},
    Map<String, String> links = const {},
    Set<String> refused = const {},
  }) : files = {...files},
       links = {...links},
       refused = {...refused};

  /// Paths that hold a file.
  final Set<String> files;

  /// Reparse-point components, mapped to their target.
  final Map<String, String> links;

  /// Paths [fileExists] answers `null` for — the OS declining to say.
  ///
  /// A path is also refused when any *component* of it is listed here, because
  /// a refusal is about the route rather than the leaf. Note that Windows does
  /// **not** do this for `File.existsSync` behind an untrusted mount point — it
  /// answers a flat `false`, which is why the junction cases below describe
  /// `links` and leave this empty.
  final Set<String> refused;

  /// Every path this probe was asked about, so a test can count work.
  final List<String> queries = [];

  @override
  bool? fileExists(String path) {
    queries.add(path);
    if (_isRefused(path)) return null;
    return files.contains(path);
  }

  @override
  bool isLink(String path) {
    queries.add(path);
    return links.containsKey(path);
  }

  @override
  String? linkTarget(String path) {
    queries.add(path);
    return links[path];
  }

  bool _isRefused(String path) =>
      refused.any((r) => path == r || path.startsWith('$r\\') || path.startsWith('$r/'));
}
