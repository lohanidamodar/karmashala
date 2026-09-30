import 'dart:convert';

/// A Play Console service account, as the user imported it.
class PlayAccount {
  const PlayAccount({
    required this.serviceAccountJson,
    this.reportsBucket,
    this.packageNames = const [],
  });

  /// The key file's text, whole.
  final String serviceAccountJson;

  /// The `pubsite_prod_…` bucket the console's reports land in. Ratings and
  /// installs come from it, and no API says what it is.
  final String? reportsBucket;

  /// Packages to show besides the ones the account can list by itself.
  final List<String> packageNames;

  /// The account's address, for showing which key is in use. Not a secret.
  String? get clientEmail {
    try {
      return (jsonDecode(serviceAccountJson) as Map)['client_email'] as String?;
    } on Object {
      return null;
    }
  }

  /// What is wrong with it before any call is made, or null.
  String? get problem {
    final Object? json;
    try {
      json = jsonDecode(serviceAccountJson);
    } on FormatException {
      return 'That file is not JSON.';
    }
    if (json is! Map || json['type'] != 'service_account') {
      return 'That file is not a service-account key.';
    }
    if (json['private_key'] is! String || json['client_email'] is! String) {
      return 'The key file is missing its private key or client email.';
    }
    return null;
  }

  PlayAccount copyWith({
    String? Function()? reportsBucket,
    List<String>? packageNames,
  }) => PlayAccount(
    serviceAccountJson: serviceAccountJson,
    reportsBucket: reportsBucket == null ? this.reportsBucket : reportsBucket(),
    packageNames: packageNames ?? this.packageNames,
  );

  String encode() => jsonEncode({
    'serviceAccountJson': serviceAccountJson,
    'reportsBucket': reportsBucket,
    'packageNames': packageNames,
  });

  static PlayAccount decode(String encoded) {
    final json = (jsonDecode(encoded) as Map).cast<String, Object?>();
    return PlayAccount(
      serviceAccountJson: json['serviceAccountJson']! as String,
      reportsBucket: json['reportsBucket'] as String?,
      packageNames: ((json['packageNames'] as List?) ?? const [])
          .cast<String>(),
    );
  }
}
