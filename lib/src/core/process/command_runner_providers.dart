import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'command_runner.dart';
import 'path_translator.dart';
import 'windows_command_runner.dart';

/// The command runner for the **Windows host** — used to run host tools such as
/// `wsl.exe` (e.g. for environment discovery). Overridden in tests with a
/// `FakeCommandRunner`.
final hostCommandRunnerProvider = Provider<CommandRunner>(
  (ref) => const WindowsCommandRunner(),
);

/// Provides the [PathTranslator] for explicit Windows⇄WSL path translation.
final pathTranslatorProvider = Provider<PathTranslator>(
  (ref) => const PathTranslator(),
);
