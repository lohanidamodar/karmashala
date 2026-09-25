import 'transcript_media_block.dart';

/// **How pictures are found in an agent's transcript**: a file a tool read, a
/// paste, a screenshot a tool returned.
abstract interface class AgentMediaReader {
  /// The pictures on one decoded transcript line. [calls] carries the tool
  /// calls opened on earlier lines and is updated in place.
  List<TranscriptMediaBlock> blocksIn(
    Map<Object?, Object?> json,
    TranscriptMediaCalls calls,
  );
}
