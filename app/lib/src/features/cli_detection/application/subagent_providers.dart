import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefusalCode, DataRefused;
import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/read.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../sessions/data/server_transcripts.dart';

/// Reads one subagent's turns off disk. A seam so a test can *count* the reads,
/// which is the only way to hold "an unexpanded row costs nothing".
typedef SubagentTurnsReader =
    Future<List<TranscriptMessage>> Function(String filePath);

final subagentTurnsReaderProvider = Provider<SubagentTurnsReader>(
  (ref) => readSubagentTranscript,
);

/// Which subagent: the transcript path its `Task` row names, and the session
/// that row is in — what the server checks the path against. Without a
/// session the path is read off this client's disk.
typedef SubagentTurnsKey = ({String? sessionId, String filePath});

/// One subagent's turns, read the first time its row is expanded. Keyed by the
/// transcript path, so the same file expanded twice is not read twice.
///
/// Read by the server where the delegate wrote it when it reads transcripts
/// (Stage 0 step 6); a server that does not know the request refuses it as
/// `invalid`, and the path is then read here, as before.
final subagentTurnsProvider = FutureProvider.autoDispose
    .family<List<TranscriptMessage>, SubagentTurnsKey>((ref, key) async {
      final sessionId = key.sessionId;
      if (sessionId != null && ref.read(capabilitiesProvider).chatViaServer) {
        try {
          return await ref
              .read(serverTranscriptsProvider)
              .subagent(sessionId, key.filePath);
        } on DataRefused catch (refusal) {
          if (refusal.code != DataRefusalCode.invalid) {
            throw ServerTranscriptException(refusal.message);
          }
        }
      }
      return ref.read(subagentTurnsReaderProvider)(key.filePath);
    });
