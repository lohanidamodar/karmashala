/// The one line every log should start with: which build this is, on what.
///
/// The version is a `--dart-define` and says so when it is missing. There is no
/// runtime source for `pubspec.yaml`'s version without a plugin, and a constant
/// kept in step by hand drifts into confidently naming the wrong one.
library;

import 'dart:io';

/// Passed at build time as `--dart-define=KARMASHALA_VERSION=1.2.0+12`; empty
/// in a build that did not set it.
const String appVersion = String.fromEnvironment('KARMASHALA_VERSION');

/// `Karmashala 1.2.0+12 on windows "10.0 (Build 26100)"`, with
/// `version not recorded` in place of the version when the define is absent.
String buildIdentity() {
  final version = appVersion.isEmpty ? 'version not recorded' : appVersion;
  return 'Karmashala $version on ${Platform.operatingSystem} '
      '"${Platform.operatingSystemVersion}"';
}
