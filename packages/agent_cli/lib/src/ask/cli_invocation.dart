/// How to ask a CLI one question, and how to read its answer.
///
/// **The mode Karmashala did not have.** Everything else this package does with
/// an agent is a *session*: a process that stays up, is written to and read
/// from, and whose conversation the agent stores. This asks one question and
/// takes one answer — built by `AgentAdapter.oneShot`, so adding a CLI is its
/// adapter's business rather than a case here.
///
/// A system prompt replaces the CLI's own agent prompt: these are coding
/// agents, and left alone they will happily start reading files and running
/// commands instead of answering. Tools are disabled for the same reason — a
/// voice assistant that edits your repository because you thought aloud is not
/// what anyone asked for.
///
/// Kept as data so the arguments can be asserted in tests without running
/// anything.
class CliInvocation {
  const CliInvocation({required this.arguments, required this.parse});

  final List<String> arguments;

  /// Pulls assistant text out of one line of output. Returns null for lines
  /// that carry no text — progress, session banners, usage totals.
  final String? Function(String line) parse;
}
