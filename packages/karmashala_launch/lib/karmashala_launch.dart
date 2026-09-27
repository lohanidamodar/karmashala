/// What a terminal launches: the profiles a machine offers, an agent pane's
/// launch, the destination a command is quoted for, the argv a PTY child is
/// started with, and the shell-integration scripts it carries. Pure Dart, so
/// the server builds every launch on its own OS (slice 5a).
library;

export 'src/agent_pane_launch.dart';
export 'src/launch_context.dart';
export 'src/pty_launch.dart';
export 'src/shell_integration.dart';
export 'src/terminal_launch.dart';
export 'src/terminal_profile.dart';
export 'src/working_directory_osc.dart';
export 'src/wsl_shell_integration.dart';
