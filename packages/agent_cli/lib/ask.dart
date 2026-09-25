/// **Mode 3 — one question, one answer.**
///
/// The mode this package brought with it, and the only one that is not a
/// session: a fresh process per question, tools off, the CLI's own agent prompt
/// replaced. The appeal is authentication — someone already using `claude` or
/// `codex` has logged in, and driving the CLI reuses that.
library;

export 'src/ask/cli_session.dart';
export 'src/agents/adapter/generic_one_shot.dart';
export 'src/ask/cli_invocation.dart';
export 'src/ask/assistant_text.dart';
