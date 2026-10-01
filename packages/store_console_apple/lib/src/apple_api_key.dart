import 'dart:convert';

/// An App Store Connect team API key, as the user imported it.
class AppleApiKey {
  const AppleApiKey({
    required this.keyId,
    required this.issuerId,
    required this.privateKeyPem,
    this.vendorNumber,
  });

  final String keyId;
  final String issuerId;

  /// The `.p8` file's text: a PKCS#8 EC key between PEM markers.
  final String privateKeyPem;

  /// Sales reports are addressed by it, and no API says what it is.
  final String? vendorNumber;

  /// What is wrong with it before any call is made, or null.
  String? get problem {
    if (keyId.trim().isEmpty) return 'The key ID is missing.';
    if (issuerId.trim().isEmpty) return 'The issuer ID is missing.';
    if (!privateKeyPem.contains('BEGIN PRIVATE KEY')) {
      return 'That file is not a .p8 private key.';
    }
    return null;
  }

  AppleApiKey withVendorNumber(String? vendorNumber) => AppleApiKey(
    keyId: keyId,
    issuerId: issuerId,
    privateKeyPem: privateKeyPem,
    vendorNumber: vendorNumber,
  );

  String encode() => jsonEncode({
    'keyId': keyId,
    'issuerId': issuerId,
    'privateKeyPem': privateKeyPem,
    'vendorNumber': vendorNumber,
  });

  static AppleApiKey decode(String encoded) {
    final json = (jsonDecode(encoded) as Map).cast<String, Object?>();
    return AppleApiKey(
      keyId: json['keyId']! as String,
      issuerId: json['issuerId']! as String,
      privateKeyPem: json['privateKeyPem']! as String,
      vendorNumber: json['vendorNumber'] as String?,
    );
  }
}
