import 'dart:io';

/// Deletes a temporary directory a test made, and never fails the test for it:
/// `deleteSync(recursive: true)` blames the **top** directory when any child is
/// held, so an unguarded teardown hides the case's real failure. A copy of the
/// app's own helper — a package cannot import the app's test tree.
void removeTempDirectory(FileSystemEntity entity) {
  try {
    entity.deleteSync(recursive: true);
  } on FileSystemException {
    // Deliberately silent: the case's own verdict is the one worth reading.
  }
}
