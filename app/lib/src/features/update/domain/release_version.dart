/// A release's version as semver orders it: `major.minor.patch`, an optional
/// `-prerelease`, and a `+build` that never counts.
///
/// Read from a tag (`v1.34.27`) and from the app's own `appVersion`, which the
/// Play workflow stamps with the pubspec's build number (`1.34.27+94`), so the
/// two compare equal.
final class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(
    this.major,
    this.minor,
    this.patch, [
    this.prerelease = const [],
  ]);

  final int major;
  final int minor;
  final int patch;

  /// The dot-separated identifiers after `-`; empty for a release.
  final List<String> prerelease;

  static final _shape = RegExp(
    r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?$',
  );

  /// [raw] as a version, or null when it is not one. A leading `v` and a
  /// `+build` suffix are dropped; a missing minor or patch reads as 0.
  static ReleaseVersion? tryParse(String raw) {
    var text = raw.trim();
    if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);
    final plus = text.indexOf('+');
    if (plus >= 0) text = text.substring(0, plus);
    final match = _shape.firstMatch(text);
    if (match == null) return null;
    final pre = match.group(4);
    return ReleaseVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2) ?? '0'),
      int.parse(match.group(3) ?? '0'),
      pre == null ? const [] : pre.split('.'),
    );
  }

  bool get isPrerelease => prerelease.isNotEmpty;

  @override
  int compareTo(ReleaseVersion other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    // A release outranks any prerelease of the same core.
    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      return other.prerelease.length.sign - prerelease.length.sign;
    }
    final shared = prerelease.length < other.prerelease.length
        ? prerelease.length
        : other.prerelease.length;
    for (var i = 0; i < shared; i++) {
      final order = _compareIdentifier(prerelease[i], other.prerelease[i]);
      if (order != 0) return order;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }

  /// Numeric identifiers compare as numbers and rank below alphanumeric ones.
  static int _compareIdentifier(String a, String b) {
    final x = int.tryParse(a);
    final y = int.tryParse(b);
    if (x != null && y != null) return x.compareTo(y);
    if (x != null) return -1;
    if (y != null) return 1;
    return a.compareTo(b);
  }

  bool operator >(ReleaseVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is ReleaseVersion && compareTo(other) == 0;

  @override
  int get hashCode =>
      Object.hash(major, minor, patch, Object.hashAll(prerelease));

  @override
  String toString() =>
      '$major.$minor.$patch${prerelease.isEmpty ? '' : '-${prerelease.join('.')}'}';
}

/// Whether [tag] names a version above [current]. False when either is not a
/// version — an unstamped build (empty [current]) is never offered anything.
bool isNewerRelease(String tag, String current) {
  final offered = ReleaseVersion.tryParse(tag);
  final running = ReleaseVersion.tryParse(current);
  if (offered == null || running == null) return false;
  return offered > running;
}
