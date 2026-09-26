import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/read.dart';

/// Reads one subagent's turns off disk. A seam so a test can *count* the reads,
/// which is the only way to hold "an unexpanded row costs nothing".
typedef SubagentTurnsReader =
    Future<List<TranscriptMessage>> Function(String filePath);

final subagentTurnsReaderProvider = Provider<SubagentTurnsReader>(
  (ref) => readSubagentTranscript,
);

/// One subagent's turns, read the first time its row is expanded. Keyed by the
/// transcript path, so the same file expanded twice is not read twice.
final subagentTurnsProvider = FutureProvider.autoDispose
    .family<List<TranscriptMessage>, String>(
      (ref, filePath) => ref.read(subagentTurnsReaderProvider)(filePath),
    );
