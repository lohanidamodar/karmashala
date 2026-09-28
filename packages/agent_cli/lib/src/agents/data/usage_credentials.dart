import 'dart:convert';

import '../domain/usage_failure.dart';
import 'auth_file_io.dart';
import 'usage_exception.dart';

/// The credential file's object, read through [io], or null when it is absent.
/// One that is there and unusable is said so, not reported as "not signed in".
Future<Map<String, dynamic>?> readUsageCredential(
  String path, {
  AuthFileIo io = const LocalAuthFileIo(),
}) async {
  final read = await io.readJsonObject(path);
  if (read.failure case final failure?) {
    throw UsageException(failure, kind: UsageFailureKind.auth);
  }
  return read.object;
}

/// Decodes a credentials blob that did not come from a file.
Map<String, dynamic>? decodeUsageCredential(String? raw) {
  if (raw == null) return null;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    // Never log `raw`: it is the credential.
    return null;
  }
}

/// The `email` claim of an unverified JWT, or null.
String? emailFromJwt(String? jwt) {
  if (jwt == null) return null;
  final parts = jwt.split('.');
  if (parts.length < 2) return null;
  try {
    var payload = parts[1];
    payload += '=' * (-payload.length % 4);
    final decoded = jsonDecode(utf8.decode(base64Url.decode(payload)));
    if (decoded is Map<String, dynamic>) {
      return decoded['email'] as String?;
    }
  } catch (_) {}
  return null;
}
