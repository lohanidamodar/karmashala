/// The plain values a widget names a machine and a place on it with — a path
/// and its environment's kind — without the process runners, the command
/// layer and the I/O handles that `package:agent_cli/process.dart` brings with
/// them. A widget imports this, never that.
library;

export 'package:agent_cli/process.dart' show EnvironmentKind, EnvironmentPath;
