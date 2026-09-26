import 'package:agent_cli/process.dart';

import 'fake_command_runner.dart';
import 'package:agent_cli/read.dart';

/// A [CliStoreLocator] that hands back stores a test built on disk.
///
/// The real locator reads `%USERPROFILE%` and shells into WSL for `$HOME`, so a
/// test using it would answer questions about the machine's own CLI stores.
/// This keeps every store fixture inside the test's temp directory.
class FixedLocator extends CliStoreLocator {
  FixedLocator(this.stores) : super(runnerFor: ((_) => FakeCommandRunner()));

  final List<CliStore> stores;

  @override
  Future<List<CliStore>> locate(
    List<ExecutionEnvironment> environments,
  ) async => stores;
}
