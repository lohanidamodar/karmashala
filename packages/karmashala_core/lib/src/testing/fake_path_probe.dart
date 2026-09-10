import 'package:karmashala_core/paths.dart';

/// A described disk: which files exist, which components are reparse points and
/// where they lead, and which paths the OS refuses to answer about. Touches no
/// real filesystem, so a junction chain can be described on any host.
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

  /// Paths [fileExists] answers `null` for — the OS declining to say — and any
  /// path under them, since a refusal is about the route rather than the leaf.
  /// Windows does *not* refuse this way behind an untrusted mount point, so the
  /// junction cases describe `links` and leave this empty.
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
