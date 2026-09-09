/// Running a command somewhere: on this machine, or inside a WSL distribution.
///
/// One `CommandRunner` abstraction with a native and a WSL implementation, so
/// the same code finds and drives a CLI on Linux, on Windows, and from a
/// Windows process reaching into a distribution. Lookups go through a login
/// shell, which is what makes a CLI installed in `~/.local/bin` visible at all.
///
/// Nothing here knows about SSH; a host that reaches other machines subclasses
/// `CommandRunnerFactory` and keeps the transport (docs/PACKAGE_SPLIT.md §3).
library;

export 'src/environments/environment_kind.dart';
export 'src/environments/environment_label.dart';
export 'src/environments/environment_path.dart';
export 'src/environments/execution_environment.dart';
export 'src/environments/local_environment.dart';
export 'src/process/command_runner.dart';
export 'src/process/command_runner_factory.dart';
export 'src/process/disk_space.dart';
export 'src/process/io_process_handle.dart';
export 'src/process/local_command_runner.dart';
export 'src/process/path_translator.dart';
export 'src/process/posix_quote.dart';
export 'src/process/process_handle.dart';
export 'src/process/process_spawn.dart';
export 'src/process/process_spawner.dart';
export 'src/process/wsl_command_runner.dart';
export 'src/process/wsl_distributions.dart';
export 'src/process/wsl_interop.dart';
