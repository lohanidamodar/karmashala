import 'package:karmashala_acp/karmashala_acp.dart'
    show
        ContentBlock,
        EmbeddedResource,
        EmbeddedResourceContent,
        ResourceLinkContent;
import 'package:karmashala_session/mentions.dart';

/// A message's `@` mentions as ACP prompt blocks, put after its text.
///
/// - **A file or folder** stays its path in the words — the agent reads it
///   as written — and is also a `resource_link`, which every ACP agent takes,
///   when [linkFor] finds it in the working directory.
/// - **A diff, terminal or session** the composer fenced after the words is
///   an embedded `resource` when the agent takes [embeddedContext]; its
///   heading stays in the words so the agent knows what it is and whether it
///   was cut. Without it the fenced text goes as it came.
({String text, List<ContentBlock> blocks}) mentionPromptBlocks(
  String text, {
  required bool embeddedContext,
  required String? Function(String path) linkFor,
}) {
  final read = splitMentionedMessage(text);
  final blocks = <ContentBlock>[];
  for (final path in read.paths) {
    final uri = linkFor(path);
    if (uri == null) continue;
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    blocks.add(
      ResourceLinkContent(uri: uri, name: trimmed.split('/').last, title: path),
    );
  }
  if (!embeddedContext || read.sections.isEmpty) {
    return (text: text, blocks: blocks);
  }
  for (final section in read.sections) {
    final argument = mentionAt(section.token, 0)?.argument;
    blocks.add(
      EmbeddedResourceContent(
        EmbeddedResource(
          uri:
              'karmashala:mention/${section.kind.name}'
              '${argument == null ? '' : '/${Uri.encodeComponent(argument)}'}',
          mimeType: section.language == 'diff' ? 'text/x-diff' : 'text/plain',
          text: section.body,
        ),
      ),
    );
  }
  final attached = [for (final s in read.sections) '- ${s.heading}'];
  return (
    text: [
      if (read.text.isNotEmpty) read.text,
      'Attached:\n${attached.join('\n')}',
    ].join('\n\n'),
    blocks: blocks,
  );
}

/// An absolute [path] in the agent's spelling as a `file:` URI: a POSIX one
/// for a WSL or Unix agent, a Windows one otherwise.
String agentFileUri(String path) =>
    Uri.file(path, windows: !path.startsWith('/')).toString();
