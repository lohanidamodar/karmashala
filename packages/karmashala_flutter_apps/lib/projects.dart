/// What kind of project a directory holds, and what building it would take.
///
/// The generic sibling of the Flutter half: Gradle settings and module
/// scripts, `package.json`, the Xcode markers, the built-in kinds and the
/// artifacts each one produces — plus `ProjectScanner`, which reads those
/// files in the checkout's own environment, through a `CommandRunner` when
/// that is not this machine.
library;

export 'src/data/project_scanner.dart';
export 'src/domain/apk_output_metadata.dart';
export 'src/domain/built_in_projects.dart';
export 'src/domain/established.dart';
export 'src/domain/gradle_project.dart';
export 'src/domain/package_json.dart';
export 'src/domain/project_build.dart';
export 'src/domain/project_descriptor.dart';
export 'src/domain/project_detection.dart';
export 'src/domain/project_kind.dart';
