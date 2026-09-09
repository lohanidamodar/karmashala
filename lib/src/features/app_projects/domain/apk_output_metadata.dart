import 'dart:convert';

/// What the Android Gradle Plugin wrote beside the artifact it just built.
///
/// **This is the reason `aapt` and `apkanalyzer` are not used here.** AGP
/// writes `output-metadata.json` into the same directory as the APK, and it
/// already carries the two facts an install-and-launch needs — the
/// `applicationId` and the `outputFile`. Reading it costs one file read, comes
/// from the build itself rather than from our parse of somebody's build
/// script, and cannot disagree with the artifact it sits next to.
///
/// The alternatives were measured on 2026-09-09 against the probe APK and all
/// three agree on `com.popupbits.nativeprobe`: this file, the `applicationId`
/// literal in `app/build.gradle.kts`, and `aapt dump badging`. Given that,
/// `aapt` would be a second SDK component to locate (four build-tools versions
/// are installed here) and a subprocess to spawn, for an answer already on
/// disk.
class ApkOutputMetadata {
  const ApkOutputMetadata({
    required this.applicationId,
    required this.variantName,
    required this.outputFile,
  });

  final String applicationId;

  /// `debug`, `release`, or a flavour's variant.
  final String variantName;

  /// The APK's file name, relative to the directory the metadata sits in.
  ///
  /// Read rather than assumed: AGP names it after the module's archives base
  /// name, so a module called `:mobile` produces `mobile-debug.apk` and the
  /// descriptor's `<module>-debug.apk` is a guess this replaces.
  final String outputFile;

  Map<String, Object?> toJson() => <String, Object?>{
    'applicationId': applicationId,
    'variantName': variantName,
    'outputFile': outputFile,
  };
}

/// Reads AGP's `output-metadata.json`, or **null when it does not say** —
/// which is not an empty application id (§19).
ApkOutputMetadata? readApkOutputMetadata(String contents) {
  final Object? decoded;
  try {
    decoded = jsonDecode(contents);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final applicationId = decoded['applicationId'];
  if (applicationId is! String || applicationId.isEmpty) return null;
  final elements = decoded['elements'];
  String? outputFile;
  if (elements is List && elements.isNotEmpty) {
    final first = elements.first;
    if (first is Map<String, Object?> && first['outputFile'] is String) {
      outputFile = first['outputFile'] as String;
    }
  }
  if (outputFile == null || outputFile.isEmpty) return null;
  final variant = decoded['variantName'];
  return ApkOutputMetadata(
    applicationId: applicationId,
    variantName: variant is String ? variant : '',
    outputFile: outputFile,
  );
}
