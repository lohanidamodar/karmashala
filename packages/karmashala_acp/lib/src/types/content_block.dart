import 'package:meta/meta.dart';

import '../json.dart';

/// A piece of a prompt or of an agent's message. The types follow MCP's
/// content blocks; one this package has no class for parses as
/// [UnknownContent] and goes back out unchanged.
@immutable
sealed class ContentBlock {
  const ContentBlock();

  const factory ContentBlock.text(String text) = TextContent;

  factory ContentBlock.fromJson(JsonMap json) {
    final type = json.string('type');
    return switch (type) {
      'text' => TextContent(
        json.string('text') ?? '',
        annotations: json.object('annotations'),
      ),
      'image' => ImageContent(
        data: json.string('data') ?? '',
        mimeType: json.string('mimeType') ?? '',
        uri: json.string('uri'),
      ),
      'audio' => AudioContent(
        data: json.string('data') ?? '',
        mimeType: json.string('mimeType') ?? '',
      ),
      'resource_link' => ResourceLinkContent(
        uri: json.string('uri') ?? '',
        name: json.string('name') ?? '',
        title: json.string('title'),
        description: json.string('description'),
        mimeType: json.string('mimeType'),
        size: json.integer('size'),
      ),
      'resource' => EmbeddedResourceContent(
        EmbeddedResource.fromJson(json.object('resource') ?? const {}),
      ),
      _ => UnknownContent(type ?? '', json),
    };
  }

  String get type;

  JsonMap toJson();
}

final class TextContent extends ContentBlock {
  const TextContent(this.text, {this.annotations});

  final String text;
  final JsonMap? annotations;

  @override
  String get type => 'text';

  @override
  JsonMap toJson() =>
      withoutNulls({'type': type, 'text': text, 'annotations': annotations});
}

final class ImageContent extends ContentBlock {
  const ImageContent({required this.data, required this.mimeType, this.uri});

  /// Base64.
  final String data;
  final String mimeType;
  final String? uri;

  @override
  String get type => 'image';

  @override
  JsonMap toJson() => withoutNulls({
    'type': type,
    'data': data,
    'mimeType': mimeType,
    'uri': uri,
  });
}

final class AudioContent extends ContentBlock {
  const AudioContent({required this.data, required this.mimeType});

  /// Base64.
  final String data;
  final String mimeType;

  @override
  String get type => 'audio';

  @override
  JsonMap toJson() => {'type': type, 'data': data, 'mimeType': mimeType};
}

final class ResourceLinkContent extends ContentBlock {
  const ResourceLinkContent({
    required this.uri,
    required this.name,
    this.title,
    this.description,
    this.mimeType,
    this.size,
  });

  final String uri;
  final String name;
  final String? title;
  final String? description;
  final String? mimeType;
  final int? size;

  @override
  String get type => 'resource_link';

  @override
  JsonMap toJson() => withoutNulls({
    'type': type,
    'uri': uri,
    'name': name,
    'title': title,
    'description': description,
    'mimeType': mimeType,
    'size': size,
  });
}

final class EmbeddedResourceContent extends ContentBlock {
  const EmbeddedResourceContent(this.resource);

  final EmbeddedResource resource;

  @override
  String get type => 'resource';

  @override
  JsonMap toJson() => {'type': type, 'resource': resource.toJson()};
}

/// The body of an embedded resource: text, or a base64 blob.
@immutable
final class EmbeddedResource {
  const EmbeddedResource({
    required this.uri,
    this.mimeType,
    this.text,
    this.blob,
  });

  factory EmbeddedResource.fromJson(JsonMap json) => EmbeddedResource(
    uri: json.string('uri') ?? '',
    mimeType: json.string('mimeType'),
    text: json.string('text'),
    blob: json.string('blob'),
  );

  final String uri;
  final String? mimeType;
  final String? text;
  final String? blob;

  JsonMap toJson() => withoutNulls({
    'uri': uri,
    'mimeType': mimeType,
    'text': text,
    'blob': blob,
  });
}

/// A content type this package has no class for; [raw] is the whole block.
final class UnknownContent extends ContentBlock {
  const UnknownContent(this.type, this.raw);

  @override
  final String type;
  final JsonMap raw;

  @override
  JsonMap toJson() => raw;
}

List<ContentBlock> contentBlocksFromJson(List<JsonMap>? items) => [
  for (final item in items ?? const <JsonMap>[]) ContentBlock.fromJson(item),
];
