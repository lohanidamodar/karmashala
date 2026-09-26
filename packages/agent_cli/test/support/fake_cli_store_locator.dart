import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';

import 'fake_command_runner.dart';

/// A [CliStoreLocator] that hands back stores a test built.
///
/// The real locator reads `%USERPROFILE%` and shells into WSL for `$HOME`, so a
/// test using it would answer questions about the machine's own CLI stores.
/// This keeps every store fixture inside the test.
class FixedLocator extends CliStoreLocator {
  FixedLocator(this.stores)
    : super(runnerFor: ((_) => FakeCommandRunner()), environment: const {});

  final List<CliStore> stores;

  @override
  Future<List<CliStore>> locate(
    List<ExecutionEnvironment> environments,
  ) async => stores;
}
