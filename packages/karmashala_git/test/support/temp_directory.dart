// Copied from packages/agent_cli/test/support/temp_directory.dart —
// a package cannot import another package's test tree.
import 'dart:io';

/// Deletes a temporary directory a test made, and never fails the test for it.
///
/// `deleteSync(recursive: true)` names the **top** directory when any child
/// cannot be removed, so an unguarded teardown replaces a case's real failure
/// with a `PathNotFoundException` about a path in `%TEMP%`. Windows also holds a
/// handle briefly after a process exits, so a refusal here is normal.
void removeTempDirectory(FileSystemEntity entity) {
  try {
    entity.deleteSync(recursive: true);
  } on FileSystemException {
    // Deliberately silent: the case's own verdict is the one worth reading.
  }
}
