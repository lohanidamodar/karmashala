import 'dart:io';

/// Deletes a temporary directory a test made, and never fails the test for it.
///
/// A copy of the app's `test/support/temp_directory.dart`, which 70 app suites
/// still use; a package cannot import the app's test tree. Keep the two in
/// step, or give the package a `testing.dart` library that both can import.
///
/// The guard is not tidiness. `deleteSync(recursive: true)` names the **top**
/// directory when any child cannot be removed, so an unguarded teardown turns a
/// case's real failure into a `PathNotFoundException` about a path in `%TEMP%`.
/// Windows also holds a handle for a moment after the process that had it
/// exits, so a refusal here is a normal outcome and not a fault.
void removeTempDirectory(FileSystemEntity entity) {
  try {
    entity.deleteSync(recursive: true);
  } on FileSystemException {
    // Deliberately silent: the case's own verdict is the one worth reading.
  }
}
