part of '../remote_payloads.dart';

/// What a file sent to one session may be, or the host's sentence for why none
/// may be. The host words the refusal because only it knows which of the several
/// reasons applies.
class RemoteAttachmentSupport {
  const RemoteAttachmentSupport({
    required this.mediaTypes,
    required this.maxBytes,
    this.refusal,
  });

  /// Nothing may be sent here, and this is why — in the host's own words.
  const RemoteAttachmentSupport.refused(String reason)
    : mediaTypes = const [],
      maxBytes = 0,
      refusal = reason;

  /// The exact media types the agent will look at. Never a wildcard: the phone
  /// hands one of these back verbatim and the host matches it literally.
  final List<String> mediaTypes;

  /// The largest file this session will take, in bytes. Never above
  /// [kMaxAttachmentBytes]; may be below it.
  final int maxBytes;

  /// Why [mediaTypes] is empty, when the host can say. Null with an empty list
  /// means it had no words for it.
  final String? refusal;

  bool get allowsAnything => mediaTypes.isNotEmpty && maxBytes > 0;

  Map<String, Object?> toJson() => {
    'types': mediaTypes,
    'max': maxBytes,
    if (refusal != null) 'why': refusal,
  };

  /// An absent or malformed value reads as null — *we were not told* — which
  /// is not the same as being told nothing is allowed.
  static RemoteAttachmentSupport? parse(Object? json) {
    if (json is! Map) return null;
    final max = json['max'];
    final why = json['why'];
    return RemoteAttachmentSupport(
      mediaTypes: [
        for (final type in (json['types'] as List? ?? const []))
          if (type is String && type.isNotEmpty) type,
      ],
      maxBytes: max is int && max > 0 ? max : 0,
      refusal: why is String && why.isNotEmpty ? why : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteAttachmentSupport &&
      other.maxBytes == maxBytes &&
      other.refusal == refusal &&
      other.mediaTypes.length == mediaTypes.length &&
      other.mediaTypes.every(mediaTypes.contains);

  @override
  int get hashCode =>
      Object.hash(maxBytes, refusal, Object.hashAll(mediaTypes));
}

/// What became of a prompt: typed into the agent, or left in the desktop's own
/// message box. Told rather than inferred, because "sent" would be false for
/// the second.
enum RemotePromptDelivery {
  sent('sent'),
  offered('offered');

  const RemotePromptDelivery(this.wire);

  final String wire;

  /// An unknown word from a newer host reads as [sent] — the behaviour every
  /// build before this one had.
  static RemotePromptDelivery parse(Object? wire) =>
      wire == offered.wire ? offered : sent;
}

/// The phone declaring a file before any of it is sent.
class RemoteAttachmentBegin {
  const RemoteAttachmentBegin({
    required this.sessionId,
    required this.name,
    required this.mediaType,
    required this.bytes,
  });

  final String sessionId;

  /// The file's name as the phone knows it. **A hint, never a path**: the host
  /// keeps a sanitised basename and puts its own extension on.
  final String name;

  /// One of the session's [RemoteAttachmentSupport.mediaTypes], exactly.
  final String mediaType;

  /// The whole file's length, declared up front so the host can refuse an
  /// oversized file before a byte crosses.
  final int bytes;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'name': name,
    'type': mediaType,
    'bytes': bytes,
  };

  static RemoteAttachmentBegin fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    final name = json['name'];
    final type = json['type'];
    final bytes = json['bytes'];
    if (sessionId is! String ||
        name is! String ||
        type is! String ||
        bytes is! int) {
      throw const ProtocolException('bad attachment request');
    }
    return RemoteAttachmentBegin(
      sessionId: sessionId,
      name: name,
      mediaType: type,
      bytes: bytes,
    );
  }
}

/// The host agreeing to take a file, and saying how to hand it over.
class RemoteAttachmentOffer {
  const RemoteAttachmentOffer({
    required this.uploadId,
    required this.chunkBytes,
  });

  /// Names this upload for the life of the link. Nothing is a file until a
  /// `prompt.send` quotes it, and nothing outside that link can quote it.
  final String uploadId;

  /// Raw bytes per `attachment.chunk`. Sent rather than assumed so an older
  /// phone and a newer host cannot disagree about it.
  final int chunkBytes;

  Map<String, Object?> toJson() => {
    'uploadId': uploadId,
    'chunkBytes': chunkBytes,
  };

  static RemoteAttachmentOffer fromJson(Map<String, Object?> json) {
    final uploadId = json['uploadId'];
    final chunk = json['chunkBytes'];
    if (uploadId is! String || uploadId.isEmpty || chunk is! int || chunk < 1) {
      throw const ProtocolException('bad attachment offer');
    }
    return RemoteAttachmentOffer(uploadId: uploadId, chunkBytes: chunk);
  }
}
