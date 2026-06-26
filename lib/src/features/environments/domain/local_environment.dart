import 'environment_kind.dart';
import 'execution_environment.dart';

/// Stable id of the always-present local **Windows-native** execution
/// environment — the host the desktop app runs on.
///
/// Discovering *all* environments (including WSL distributions) is Loop 3; this
/// constant lets earlier loops attach local paths to a real environment row.
const String localWindowsEnvironmentId = 'windows';

/// Builds the local Windows-native [ExecutionEnvironment] record.
ExecutionEnvironment localWindowsEnvironment(DateTime createdAt) =>
    ExecutionEnvironment(
      id: localWindowsEnvironmentId,
      kind: EnvironmentKind.windowsNative,
      name: 'Windows',
      createdAt: createdAt,
    );
