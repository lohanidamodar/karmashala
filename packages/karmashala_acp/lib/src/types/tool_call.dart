import 'package:meta/meta.dart';

import '../json.dart';
import 'content_block.dart';

/// What a tool call produced so far.
@immutable
sealed class ToolCallContent {
  const ToolCallContent();

  factory ToolCallContent.fromJson(JsonMap json) {
    final type = json.string('type');
    return switch (type) {
      'content' => ToolCallContentBlock(
        ContentBlock.fromJson(json.object('content') ?? const {}),
      ),
      'diff' => ToolCallDiff(
        path: json.string('path') ?? '',
        oldText: json.string('oldText'),
        newText: json.string('newText') ?? '',
      ),
      'terminal' => ToolCallTerminal(json.string('terminalId') ?? ''),
      _ => UnknownToolCallContent(type ?? '', json),
    };
  }

  JsonMap toJson();
}

final class ToolCallContentBlock extends ToolCallContent {
  const ToolCallContentBlock(this.content);

  final ContentBlock content;

  @override
  JsonMap toJson() => {'type': 'content', 'content': content.toJson()};
}

final class ToolCallDiff extends ToolCallContent {
  const ToolCallDiff({required this.path, this.oldText, required this.newText});

  final String path;

  /// `null` for a file the tool created.
  final String? oldText;
  final String newText;

  @override
  JsonMap toJson() => {
    'type': 'diff',
    'path': path,
    'oldText': oldText,
    'newText': newText,
  };
}

final class ToolCallTerminal extends ToolCallContent {
  const ToolCallTerminal(this.terminalId);

  final String terminalId;

  @override
  JsonMap toJson() => {'type': 'terminal', 'terminalId': terminalId};
}

final class UnknownToolCallContent extends ToolCallContent {
  const UnknownToolCallContent(this.type, this.raw);

  final String type;
  final JsonMap raw;

  @override
  JsonMap toJson() => raw;
}

/// A file a tool call touches, so a client can follow along.
@immutable
final class ToolCallLocation {
  const ToolCallLocation(this.path, {this.line});

  factory ToolCallLocation.fromJson(JsonMap json) =>
      ToolCallLocation(json.string('path') ?? '', line: json.integer('line'));

  final String path;
  final int? line;

  JsonMap toJson() => withoutNulls({'path': path, 'line': line});

  @override
  bool operator ==(Object other) =>
      other is ToolCallLocation && other.path == path && other.line == line;

  @override
  int get hashCode => Object.hash(path, line);
}
