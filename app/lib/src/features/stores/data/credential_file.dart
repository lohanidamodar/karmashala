import 'dart:io';

/// Why a picked credential file gave no text, as a sentence for the form.
class CredentialFileException implements Exception {
  const CredentialFileException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A key file is a few kilobytes; anything past this is the wrong file.
const int kCredentialFileMaxBytes = 256 * 1024;

/// The text of the credential file at [path], read once at import. Its
/// contents go to the vault and nowhere else.
Future<String> readCredentialFile(String path) async {
  final file = File(path);
  try {
    if (await file.length() > kCredentialFileMaxBytes) {
      throw const CredentialFileException(
        'That file is too large to be a key file.',
      );
    }
    return await file.readAsString();
  } on CredentialFileException {
    rethrow;
  } on FileSystemException {
    throw const CredentialFileException('That file could not be read.');
  } on FormatException {
    throw const CredentialFileException('That file is not text.');
  }
}
