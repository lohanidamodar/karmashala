import 'dart:convert';

/// What AGP wrote beside the artifact: the `applicationId` and the `outputFile`,
/// one file read. Crossed against `aapt dump badging` and the script literal.
class ApkOutputMetadata {
  const ApkOutputMetadata({
    required this.applicationId,
    required this.variantName,
    required this.outputFile,
  });

  final String applicationId;

  /// `debug`, `release`, or a flavour's variant.
  final String variantName;

  /// The APK's file name, relative to the metadata's directory. Read rather
  /// than assumed: AGP names it after the module's archives base name.
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
