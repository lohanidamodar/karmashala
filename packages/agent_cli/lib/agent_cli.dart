/// Discovers and drives already-installed AI coding CLIs — Claude Code, Codex,
/// Antigravity and Gemini CLI — on this machine and inside its WSL
/// distributions.
///
/// **Five modes over one descriptor table** (`descriptors.dart`):
///
/// * `launch.dart` — the argv for an interactive session in a terminal pane;
/// * `stream.dart` — a conversation over the CLI's own stream protocol;
/// * `ask.dart` — one question, one answer, tools off;
/// * `read.dart` — the conversations the CLIs already wrote, read off disk;
/// * `usage.dart` — tokens, rate limits and which account is signed in.
///
/// Plus `discovery.dart` (which environments exist, and what is installed in
/// each) and `process.dart` (the runners everything above executes through).
///
/// Import this library for all of it, or one of the above for the part you
/// want.
library;

export 'ask.dart';
export 'descriptors.dart';
export 'discovery.dart';
export 'launch.dart';
export 'process.dart';
export 'read.dart';
export 'stream.dart';
export 'usage.dart';
