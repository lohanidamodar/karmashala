import 'dart:convert';
import 'dart:io';

import 'package:karmashala_acp/karmashala_acp.dart'
    show ImageContent, TextContent;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_host/src/acp/acp_prompt_images.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// Images a composer attached go to an agent that takes them as ACP image
/// blocks, not as paths; an agent that does not is sent the paths, as before,
/// and the sender is told so.
void main() {
  late AppDatabase database;
  late Directory temp;

  /// A 1x1 transparent PNG.
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
    '60e6kgAAAABJRU5ErkJggg==',
  );

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_images_test');
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  String image(String name) {
    final file = File(p.join(temp.path, name))..writeAsBytesSync(png);
    return file.path;
  }

  group('the attachment block', () {
    test('is read off the message, files left where they were', () {
      final split = splitAttachedImages(
        'Look at these\n\nAttached image(s):\n/a/one.png\n/b/two shot.jpg'
        '\n\nAttached file(s):\n/c/notes.txt',
      );
      expect(split.paths, ['/a/one.png', '/b/two shot.jpg']);
      expect(
        split.textWithout({'/a/one.png', '/b/two shot.jpg'}),
        'Look at these\n\nAttached file(s):\n/c/notes.txt',
      );
      expect(
        split.textWithout({'/a/one.png'}),
        'Look at these\n\nAttached image(s):\n/b/two shot.jpg'
        '\n\nAttached file(s):\n/c/notes.txt',
      );
    });

    test('an image-only message, and one with none', () {
      final only = splitAttachedImages('Attached image(s):\n/a/one.png');
      expect(only.paths, ['/a/one.png']);
      expect(only.textWithout({'/a/one.png'}), '');
      final none = splitAttachedImages('Attached image(s) are nice');
      expect(none.paths, isEmpty);
      expect(none.textWithout(const {}), 'Attached image(s) are nice');
    });
  });

  test('an agent that takes images is sent each as an image block, and the '
      'transcript keeps the message as it was typed', () async {
    final shot = image('shot.png');
    final process = FakeAcpProcess(
      FakeAcpAgent(supportsImages: true, turns: const [FakeTurn([])]),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
    );
    await runtime.start();
    final typed = 'What is this?\n\nAttached image(s):\n$shot';
    expect(await runtime.send(typed), isNull);
    await runtime.awaitTurn();

    final prompt = process.agent.prompts.single;
    expect(prompt, hasLength(2));
    expect((prompt[0] as TextContent).text, 'What is this?');
    final block = prompt[1] as ImageContent;
    expect(block.mimeType, 'image/png');
    expect(base64Decode(block.data), png);
    expect(SessionMessageDao(database).listAfter('s1').first.text, typed);
    await runtime.stop();
  });

  test('an image that cannot be read stays a path, and the sender is told',
      () async {
    final shot = image('shot.png');
    final gone = p.join(temp.path, 'gone.png');
    final process = FakeAcpProcess(
      FakeAcpAgent(supportsImages: true, turns: const [FakeTurn([])]),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
    );
    await runtime.start();
    final notice = await runtime.send('Two\n\nAttached image(s):\n$shot\n$gone');
    await runtime.awaitTurn();

    final prompt = process.agent.prompts.single;
    expect(
      (prompt[0] as TextContent).text,
      'Two\n\nAttached image(s):\n$gone',
    );
    expect(prompt.whereType<ImageContent>(), hasLength(1));
    expect(notice, contains('gone.png'));
    expect(notice, contains('as its path'));
    await runtime.stop();
  });

  test('an agent that does not take images is sent the paths, as before, '
      'and the sender is told why', () async {
    final shot = image('shot.png');
    final process = FakeAcpProcess(FakeAcpAgent(turns: const [FakeTurn([])]));
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
    );
    await runtime.start();
    final typed = 'What is this?\n\nAttached image(s):\n$shot';
    final notice = await runtime.send(typed);
    await runtime.awaitTurn();

    final prompt = process.agent.prompts.single;
    expect(prompt, hasLength(1));
    expect((prompt.single as TextContent).text, typed);
    expect(notice, contains('does not take images'));
    await runtime.stop();
  });

  test('a message with no images says nothing', () async {
    final process = FakeAcpProcess(FakeAcpAgent(turns: const [FakeTurn([])]));
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
    );
    await runtime.start();
    expect(await runtime.send('hello'), isNull);
    await runtime.awaitTurn();
    expect((process.agent.prompts.single.single as TextContent).text, 'hello');
    await runtime.stop();
  });
}
