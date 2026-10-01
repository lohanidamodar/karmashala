import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../data/credential_file.dart';

export '../data/credential_file.dart' show CredentialFileException;

/// Reads a picked credential file's text; a provider so a test needs no file.
typedef CredentialFileReader = Future<String> Function(String path);

final credentialFileReaderProvider = Provider<CredentialFileReader>(
  (ref) => readCredentialFile,
);

/// Whether this client may import, change or remove a store credential. The
/// server refuses all three from a phone, and a phone is the client that
/// cannot host a server.
final storeCredentialsWritableProvider = Provider<bool>(
  (ref) => ref.watch(capabilitiesProvider).hostsServer,
);

/// Package names as typed: separated by commas or new lines, blanks and
/// repeats dropped.
List<String> parsePackageNames(String typed) => {
  for (final part in typed.split(RegExp(r'[,\s]+')))
    if (part.trim().isNotEmpty) part.trim(),
}.toList();
