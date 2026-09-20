/// The exact words an agent is told about a pull request.
///
/// Rendered from a snapshot the app already read, deterministically and in one
/// place, so the preview a user approves and the string that reaches the PTY
/// cannot be two different things.
library;

export 'src/github/domain/pull_request_context.dart';
