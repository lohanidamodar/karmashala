import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/read.dart';

/// Reads one subagent's turns off disk.
///
/// A seam, not an abstraction: it exists so a test can *count* the reads, which
/// is the only way to hold the promise that an unexpanded row costs nothing.
typedef SubagentTurnsReader =
    Future<List<TranscriptMessage>> Function(String filePath);

final subagentTurnsReaderProvider = Provider<SubagentTurnsReader>(
  (ref) => readSubagentTranscript,
);

/// One subagent's turns, read the first time its row is expanded and kept for
/// as long as something is watching.
///
/// Keyed by the transcript's path rather than by the [SubagentRef] because the
/// path *is* the identity — and because the same file expanded twice must not
/// be read twice. The delegate transcripts behind one real session here total
/// 1,485 MiB, so eagerness is not a rounding error.
final subagentTurnsProvider = FutureProvider.autoDispose
    .family<List<TranscriptMessage>, String>(
      (ref, filePath) => ref.read(subagentTurnsReaderProvider)(filePath),
    );
