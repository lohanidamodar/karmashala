part of 'remote_companion_gateway.dart';

// An attachment on its way to the desktop: declared first, then sent in the
// chunks the host asked for. The prompt that commits it stays with
// `sendPrompt` — this answers with the id that prompt names.

extension _GatewayAttachments on RemoteCompanionGateway {
  /// Sends one attachment and answers with the upload id the prompt commits.
  Future<String> _uploadAttachment(
    CompanionClient client,
    String sessionId,
    CompanionOutgoingAttachment attachment,
    void Function(int sent, int total)? onProgress,
  ) async {
    // Declared first, so a refusal costs one small frame rather than the
    // megabytes of a photo the desktop cannot use.
    final offer = await _mapRefusals(
      () => client.beginAttachment(
        RemoteAttachmentBegin(
          sessionId: sessionId,
          name: attachment.name,
          mediaType: attachment.mediaType,
          bytes: attachment.bytes.length,
        ),
      ),
    );
    final total = (attachment.bytes.length / offer.chunkBytes).ceil();
    onProgress?.call(0, total);
    var seq = 0;
    for (var at = 0; at < attachment.bytes.length; at += offer.chunkBytes) {
      final end = at + offer.chunkBytes < attachment.bytes.length
          ? at + offer.chunkBytes
          : attachment.bytes.length;
      // Awaited one at a time. The outbound queue drops its oldest frame under
      // pressure, so a slice nobody acknowledged is a slice that is gone.
      await _mapRefusals(
        () => client.sendAttachmentChunk(
          offer.uploadId,
          seq,
          Uint8List.sublistView(attachment.bytes, at, end),
        ),
      );
      onProgress?.call(++seq, total);
    }
    return offer.uploadId;
  }
}
