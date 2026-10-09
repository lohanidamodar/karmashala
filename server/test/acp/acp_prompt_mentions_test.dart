import 'dart:io';

import 'package:karmashala_acp/karmashala_acp.dart'
    show EmbeddedResourceContent, ResourceLinkContent, TextContent;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_host/src/acp/acp_prompt_mentions.dart';
import 'package:karmashala_session/mentions.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// `@` mentions reach an ACP agent as content blocks: a file as a
/// `resource_link` beside its path in the words, a diff, terminal or session
/// as an embedded `resource` when the agent takes embedded context.
void main() {
  final withTerminal =
      messageWithMentionContexts('Fix @lib/a.dart per @terminal:Build', const [
        MentionContext(
          token: '@terminal:Build',
          description: 'last 200 lines of Build',
          body: 'error: a.dart:3',
          keepTail: true,
        ),
      ]);

  group('mentionPromptBlocks', () {
    test('links each file it can find and embeds each section', () {
      final (:text, :blocks) = mentionPromptBlocks(
        withTerminal,
        embeddedContext: true,
        linkFor: (path) => path == 'lib/a.dart' ? 'file:///w/lib/a.dart' : null,
      );
      expect(
        text,
        'Fix @lib/a.dart per @terminal:Build\n\n'
        'Attached:\n- @terminal:Build — last 200 lines of Build',
      );
      expect(blocks, hasLength(2));
      final link = blocks[0] as ResourceLinkContent;
      expect(link.uri, 'file:///w/lib/a.dart');
      expect(link.name, 'a.dart');
      final embedded = (blocks[1] as EmbeddedResourceContent).resource;
      expect(embedded.uri, 'karmashala:mention/terminal/Build');
      expect(embedded.mimeType, 'text/plain');
      expect(embedded.text, 'error: a.dart:3');
    });

    test('without embedded context the fenced text goes as it came', () {
      final (:text, :blocks) = mentionPromptBlocks(
        withTerminal,
        embeddedContext: false,
        linkFor: (_) => null,
      );
      expect(text, withTerminal);
      expect(blocks, isEmpty);
    });

    test('agentFileUri spells POSIX and Windows paths', () {
      expect(agentFileUri('/home/me/w/a.dart'), 'file:///home/me/w/a.dart');
      expect(agentFileUri(r'C:\w\a b.dart'), 'file:///C:/w/a%20b.dart');
    });
  });

  group('over a fake agent', () {
    late AppDatabase database;
    late Directory temp;

    setUp(() {
      database = AppDatabase.memory();
      database.execute('PRAGMA foreign_keys = OFF;');
      temp = Directory.systemTemp.createTempSync('acp_mentions_test');
      Directory(p.join(temp.path, 'lib')).createSync();
      File(p.join(temp.path, 'lib', 'a.dart')).writeAsStringSync('main() {}');
    });

    tearDown(() {
      database.close();
      temp.deleteSync(recursive: true);
    });

    test('a file that is there is linked, one that is not stays words, and '
        'the transcript keeps the message as sent', () async {
      final process = FakeAcpProcess(FakeAcpAgent(turns: const [FakeTurn([])]));
      final runtime = runtimeOver(
        process,
        database: database,
        workingDirectory: temp.path,
      );
      await runtime.start();
      final sent = '$withTerminal\n\nAnd @lib/gone.dart';
      expect(await runtime.send(sent), isNull);
      await runtime.awaitTurn();

      final prompt = process.agent.prompts.single;
      expect(prompt, hasLength(3));
      expect((prompt[0] as TextContent).text, contains('@lib/gone.dart'));
      final link = prompt[1] as ResourceLinkContent;
      expect(
        link.uri,
        Uri.file(
          p.join(temp.path, 'lib', 'a.dart'),
          windows: Platform.isWindows,
        ).toString(),
      );
      expect(
        (prompt[2] as EmbeddedResourceContent).resource.text,
        'error: a.dart:3',
      );
      expect(SessionMessageDao(database).listAfter('s1').first.text, sent);
      await runtime.stop();
    });
  });
}
