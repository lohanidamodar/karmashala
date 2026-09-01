/// The one line every log should start with: which build this is, on what.
///
/// A log that does not say which version produced it is guesswork to read. The
/// owner's own reports have arrived as a copied log with no way to tell whether
/// the fix being discussed was even in the running build — and on a phone,
/// where the companion may be several releases behind the desktop it is talking
/// to, that question is the first one worth answering.
///
/// **The version is a `--dart-define`, and says so when it is missing.** There
/// is no runtime source for `pubspec.yaml`'s version without a plugin, and the
/// alternative — a constant in `lib/` kept in step by hand — drifts silently,
/// which is worse than absent: a log confidently naming the wrong version costs
/// more than one that admits it does not know. The app already builds with
/// `--dart-define=KARMASHALA_MODE=companion`, so this follows a path that
/// exists rather than inventing one.
library;

import 'dart:io';

/// Passed at build time as `--dart-define=KARMASHALA_VERSION=1.2.0+12`.
/// Empty in any build that did not set it, which is reported honestly below.
const String appVersion = String.fromEnvironment('KARMASHALA_VERSION');

/// Passed as `--dart-define=KARMASHALA_MODE=companion` by the companion build.
const String appMode = String.fromEnvironment(
  'KARMASHALA_MODE',
  defaultValue: 'desktop',
);

/// `Karmashala 1.2.0+12 (desktop) on windows "10.0 (Build 26100)"`, with
/// `version not recorded` in place of the version when the define is absent.
String buildIdentity() {
  final version = appVersion.isEmpty ? 'version not recorded' : appVersion;
  // `operatingSystemVersion` is free, always present, and is the half of this
  // that a bug report can never supply accurately from memory.
  return 'Karmashala $version ($appMode) on ${Platform.operatingSystem} '
      '"${Platform.operatingSystemVersion}"';
}
