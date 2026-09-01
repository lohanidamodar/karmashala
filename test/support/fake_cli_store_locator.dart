import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';

import 'fake_command_runner.dart';

/// A [CliStoreLocator] that hands back stores a test built on disk.
///
/// The real locator reads `%USERPROFILE%` and shells into WSL for `$HOME`, so a
/// test using it would answer questions about the machine's own CLI stores.
/// This keeps every store fixture inside the test's temp directory.
class FixedLocator extends CliStoreLocator {
  FixedLocator(this.stores) : super(runnerFactory: FakeCommandRunnerFactory());

  final List<CliStore> stores;

  @override
  Future<List<CliStore>> locate(
    List<ExecutionEnvironment> environments,
  ) async => stores;
}
