import 'dart:io';

/// Deletes a temporary directory a test made, and never fails the test for it:
/// `deleteSync(recursive: true)` names the *top* directory when any child is
/// still held, replacing a case's real failure with a `%TEMP%` path error.
///
/// Duplicated from the app's `test/support/temp_directory.dart` — no package
/// can import the app's test tree. Keep the two in step.
void removeTempDirectory(FileSystemEntity entity) {
  try {
    entity.deleteSync(recursive: true);
  } on FileSystemException {
    // Deliberately silent: the case's own verdict is the one worth reading.
  }
}
