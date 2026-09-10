/// **Tier a diff, never filter it.**
///
/// Every changed file stays in the list; only the order changes. A path this file
/// has no opinion about is [ReviewTier.source] — the *first* tier — because
/// guessing wrong that way pushes a hand-written change below a lockfile.
library;

/// How much of a reviewer's attention a changed path is likely to be worth,
/// most first. The declaration order **is** the sort order.
enum ReviewTier {
  /// Hand-written code, and everything the table has no opinion about.
  source,

  /// Written by a generator from the source above, and re-written whenever it
  /// runs: `*.g.dart` (json_serializable, drift, riverpod) and `*.freezed.dart`.
  generated,

  /// A dependency lockfile. `pubspec.lock` moves on every `pub get`, and
  /// `Podfile.lock` with it on anything that builds for iOS or macOS.
  lockfile,

  /// Build output: written by a tool, read by nobody, and in a diff at all
  /// only because something is committed that should not be.
  buildOutput,
}

/// Which tier [path] falls in. Repository-relative, either slash.
///
/// A segment named `build` counts wherever it sits, not only at the root, because
/// a diff spans packages. A source directory really called `build` is demoted.
ReviewTier reviewTierOf(String path) {
  final segments = path.replaceAll(r'\', '/').split('/');
  for (final segment in segments) {
    if (segment == 'build' || segment == '.dart_tool') {
      return ReviewTier.buildOutput;
    }
  }
  final name = segments.isEmpty ? path : segments.last;
  if (name == 'pubspec.lock' || name == 'Podfile.lock') {
    return ReviewTier.lockfile;
  }
  if (name.endsWith('.g.dart') || name.endsWith('.freezed.dart')) {
    return ReviewTier.generated;
  }
  return ReviewTier.source;
}

/// [items] in tier order, **stably**: within a tier they keep the order they
/// arrived in, which is git's own and already alphabetical.
///
/// Nothing is dropped: the returned list is always the same length.
List<T> orderedForReview<T>(Iterable<T> items, String Function(T item) pathOf) {
  final buckets = <ReviewTier, List<T>>{
    for (final tier in ReviewTier.values) tier: <T>[],
  };
  for (final item in items) {
    buckets[reviewTierOf(pathOf(item))]!.add(item);
  }
  return [for (final tier in ReviewTier.values) ...buckets[tier]!];
}

/// The same order applied to the **file sections of a unified diff**, for the
/// surface that has git's text rather than a list of rows.
///
/// Sections split on `diff --git`, which git never writes inside a hunk. A
/// preamble stays where it is and an unparsable header keeps [ReviewTier.source],
/// so a diff this cannot read comes back reordered by nothing rather than mangled.
String orderUnifiedDiffForReview(String diff) {
  if (diff.isEmpty) return diff;
  const marker = 'diff --git ';
  final lines = diff.split('\n');
  final preamble = <String>[];
  final sections = <List<String>>[];
  for (final line in lines) {
    if (line.startsWith(marker)) {
      sections.add(<String>[line]);
    } else if (sections.isEmpty) {
      preamble.add(line);
    } else {
      sections.last.add(line);
    }
  }
  if (sections.length < 2) return diff;
  final ordered = orderedForReview(sections, _diffSectionPath);
  return [
    ...preamble,
    for (final section in ordered) ...section,
  ].join('\n');
}

/// The `b/` path of a `diff --git a/<old> b/<new>` header.
///
/// The `b` side, because it is the file as it now is. Read to the end of the line
/// rather than split on whitespace: a path may contain spaces.
String _diffSectionPath(List<String> section) {
  final header = section.first;
  final split = header.indexOf(' b/');
  if (split < 0) return header;
  return header.substring(split + 3);
}
