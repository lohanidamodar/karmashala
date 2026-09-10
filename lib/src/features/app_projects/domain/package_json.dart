import 'dart:convert';

/// Why a directory reads as a React Native project — two signals kept apart,
/// because a bare React Native app and an Expo app build differently.
enum ReactNativeEvidence {
  /// `react-native` among the dependencies.
  reactNative,

  /// `expo` among the dependencies — a managed project, whose build is
  /// `eas build` or `expo run:android` rather than Gradle directly.
  expo,

  /// A `metro.config.js` beside the manifest. Corroboration, never the whole
  /// answer: a package can carry one without being an app.
  metroConfig,
}

/// What one `package.json` says, as far as anything here needs to know.
class PackageJsonReading {
  const PackageJsonReading({required this.name, required this.evidence});

  final String? name;

  final Set<ReactNativeEvidence> evidence;

  /// Whether this is a React Native or Expo project at all. A `metro.config.js`
  /// alone corroborates; the answer turns on a dependency being declared.
  bool get isReactNative =>
      evidence.contains(ReactNativeEvidence.reactNative) ||
      evidence.contains(ReactNativeEvidence.expo);
}

/// Reads the two facts a React Native detection needs out of a `package.json`;
/// a file it cannot parse reads as "not React Native", the safe direction.
PackageJsonReading readPackageJson(String contents) {
  final Object? decoded;
  try {
    decoded = jsonDecode(contents);
  } on FormatException {
    return const PackageJsonReading(
      name: null,
      evidence: <ReactNativeEvidence>{},
    );
  }
  if (decoded is! Map<String, Object?>) {
    return const PackageJsonReading(
      name: null,
      evidence: <ReactNativeEvidence>{},
    );
  }

  final evidence = <ReactNativeEvidence>{};
  for (final section in const <String>['dependencies', 'devDependencies']) {
    final block = decoded[section];
    if (block is! Map<String, Object?>) continue;
    if (block.containsKey('react-native')) {
      evidence.add(ReactNativeEvidence.reactNative);
    }
    if (block.containsKey('expo')) evidence.add(ReactNativeEvidence.expo);
  }
  final name = decoded['name'];
  return PackageJsonReading(
    name: name is String && name.isNotEmpty ? name : null,
    evidence: evidence,
  );
}
