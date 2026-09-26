import 'dart:io';

/// Deletes a temporary directory a test made, and never fails the test for it.
///
/// The guard is not tidiness. `deleteSync(recursive: true)` names the **top**
/// directory when any child cannot be removed, so an unguarded teardown turns a
/// case's real failure into a `PathNotFoundException` about a path in `%TEMP%`
/// — which is exactly how a shutdown defect stayed hidden for a day (see
/// `SETTLED.md`, "The lifecycle 'flake' was a shutdown defect"). Windows also
/// holds a handle for a moment after the process that had it exits, so a
/// refusal here is a normal outcome and not a fault.
///
/// A directory left behind in `%TEMP%` costs nothing; a verdict nobody can read
/// costs a day.
void removeTempDirectory(FileSystemEntity entity) {
  try {
    entity.deleteSync(recursive: true);
  } on FileSystemException {
    // Deliberately silent: the case's own verdict is the one worth reading.
  }
}
