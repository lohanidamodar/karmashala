/// What a Gradle build says about itself, read the way `readPubspec` reads a
/// pubspec: line by line, no parser, and wrong in the safe direction.
///
/// **Deliberately not a Gradle evaluation.** A settings script is a Kotlin or
/// Groovy program and the only honest way to know what it includes is to run
/// it — which is a JVM, a daemon and thirty seconds, for a question asked
/// while somebody is looking at a list. What is read here is the shape every
/// `gradle init` and every Android Studio template writes, and a script it
/// misreads reads as "not a native Android project", so the app offers
/// nothing rather than offering to build the wrong thing.
library;

import 'dart:convert';

/// The modules a settings script includes, as Gradle spells them: `:app`.
///
/// `include(":app")`, `include ':app'` and `include ':app', ':wear'` all
/// count. `include(projects.app)` — the type-safe accessor — does not, because
/// resolving it means reading the accessor Gradle generates.
List<String> gradleIncludedModules(String contents) {
  final modules = <String>[];
  for (final raw in const LineSplitter().convert(contents)) {
    final line = _withoutComment(raw).trim();
    if (!line.startsWith('include')) continue;
    for (final value in _quotedValues(line)) {
      if (value.startsWith(':') && !modules.contains(value)) modules.add(value);
    }
  }
  return modules;
}

/// `rootProject.name`, or null when the script does not set one.
String? gradleRootProjectName(String contents) {
  for (final raw in const LineSplitter().convert(contents)) {
    final line = _withoutComment(raw).trim();
    if (!line.startsWith('rootProject.name')) continue;
    final values = _quotedValues(line);
    if (values.isNotEmpty) return values.first;
  }
  return null;
}

/// Whether a settings script makes this a **Flutter host module** rather than
/// a native Android project.
///
/// This is the discriminator that keeps `karmashala/android/` out of the
/// native path. That directory carries `com.android.application` and an
/// `applicationId`, has no `pubspec.yaml` of its own, and would answer to
/// every native marker — but its settings script `includeBuild`s
/// `flutter_tools/gradle` and applies `dev.flutter.flutter-plugin-loader`, so
/// it is the Android half of the Flutter project one directory up. Building it
/// as a native project would build somebody else's app behind their back.
bool gradleSettingsIsFlutterHost(String contents) =>
    contents.contains('dev.flutter.') ||
    contents.contains('flutter_tools/gradle') ||
    contents.contains('flutter.sdk');

/// What one module's `build.gradle(.kts)` says.
class GradleModuleReading {
  const GradleModuleReading({
    required this.pluginIds,
    required this.pluginAliases,
    this.applicationId,
    this.namespace,
  });

  /// Plugin ids applied by literal: `id("com.android.application")`,
  /// `apply plugin: 'com.android.application'`.
  final Set<String> pluginIds;

  /// Version-catalog aliases: `alias(libs.plugins.android.application)` gives
  /// `android.application`. What a fresh Android Studio project writes, so
  /// missing it would mean missing the common case.
  final Set<String> pluginAliases;

  /// The `applicationId` **literal**, or null. A computed one
  /// (`applicationId = "$base.$flavour"`) reads as null on purpose: a value
  /// Gradle assembles is one we would be guessing at, and the build's own
  /// `output-metadata.json` answers it exactly once there is a build.
  final String? applicationId;

  final String? namespace;

  /// Whether this module is a Flutter host: `dev.flutter.flutter-gradle-plugin`.
  bool get isFlutterHostModule =>
      pluginIds.any((id) => id.startsWith('dev.flutter.'));

  /// Whether this module builds an Android **application** — not a library.
  ///
  /// [catalog] maps a normalised alias to the plugin id it stands for, read
  /// from `gradle/libs.versions.toml`. Empty when there is no catalog.
  bool appliesAndroidApplication({
    Map<String, String> catalog = const <String, String>{},
  }) {
    if (pluginIds.contains(_androidApplication)) return true;
    for (final alias in pluginAliases) {
      if (catalog[alias] == _androidApplication) return true;
    }
    return false;
  }

  static const String _androidApplication = 'com.android.application';
}

/// Reads one module's build script.
GradleModuleReading readGradleModule(String contents) {
  final ids = <String>{};
  final aliases = <String>{};
  String? applicationId;
  String? namespace;

  for (final raw in const LineSplitter().convert(contents)) {
    final line = _withoutComment(raw).trim();
    if (line.isEmpty) continue;

    for (final match in _pluginId.allMatches(line)) {
      final value =
          match.group(1) ?? match.group(2) ?? match.group(3) ?? match.group(4);
      if (value != null && value.isNotEmpty) ids.add(value);
    }
    for (final match in _pluginAlias.allMatches(line)) {
      final value = match.group(1);
      if (value != null && value.isNotEmpty) aliases.add(value);
    }
    applicationId ??= _literalAfter(line, 'applicationId');
    namespace ??= _literalAfter(line, 'namespace');
  }

  return GradleModuleReading(
    pluginIds: ids,
    pluginAliases: aliases,
    applicationId: applicationId,
    namespace: namespace,
  );
}

/// The `[plugins]` table of `gradle/libs.versions.toml`, as alias → plugin id.
///
/// Keys are normalised the way Gradle generates its accessors: `-` and `_`
/// become `.`, so `android-application` and `androidApplication` both answer
/// to `libs.plugins.android.application` and `libs.plugins.androidApplication`
/// respectively.
Map<String, String> gradlePluginCatalog(String toml) {
  final catalog = <String, String>{};
  var inPlugins = false;
  for (final raw in const LineSplitter().convert(toml)) {
    final line = raw.trim();
    if (line.startsWith('[')) {
      inPlugins = line.startsWith('[plugins]');
      continue;
    }
    if (!inPlugins || line.isEmpty || line.startsWith('#')) continue;
    final equals = line.indexOf('=');
    if (equals < 0) continue;
    final key = line.substring(0, equals).trim().replaceAll(
      RegExp(r'[-_]'),
      '.',
    );
    final id = _literalAfter(line.substring(equals + 1), 'id');
    if (key.isNotEmpty && id != null) catalog[key] = id;
  }
  return catalog;
}

/// `applicationId = "com.x"`, `applicationId "com.x"` and `id = "com.x"` —
/// the three spellings Kotlin, Groovy and TOML use for the same statement.
String? _literalAfter(String line, String key) {
  final match = RegExp('(?:^|[\\s{,])$key\\s*=?\\s*([\'"])(.*?)\\1').firstMatch(line);
  return match?.group(2);
}

final RegExp _pluginId = RegExp(
  r"""\bid\s*[( ]\s*(?:"([^"]*)"|'([^']*)')|apply\s+plugin\s*:\s*(?:"([^"]*)"|'([^']*)')""",
);

final RegExp _pluginAlias = RegExp(r'alias\s*\(\s*libs\.plugins\.([\w.]+)\s*\)');

final RegExp _quoted = RegExp('"([^"]*)"' "|'([^']*)'");

List<String> _quotedValues(String line) => <String>[
  for (final match in _quoted.allMatches(line))
    match.group(1) ?? match.group(2) ?? '',
];

String _withoutComment(String line) {
  final slashes = line.indexOf('//');
  final hash = line.indexOf('#');
  var cut = -1;
  if (slashes >= 0) cut = slashes;
  if (hash >= 0 && (cut < 0 || hash < cut)) cut = hash;
  if (cut < 0) return line;
  final before = line.substring(0, cut);
  // A `//` inside a quoted value — a URL — is not a comment.
  final quotes =
      '"'.allMatches(before).length + "'".allMatches(before).length;
  return quotes.isEven ? before : line;
}
