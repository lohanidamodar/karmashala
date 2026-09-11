import 'dart:io';

import 'package:agent_cli/src/util/json_file.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// Five outcomes, told apart: the credential files used to collapse four of
/// them into "not signed in".
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('karmashala_json'));
  tearDown(() => removeTempDirectory(dir));

  String at(String name) => '${dir.path}${Platform.pathSeparator}$name';

  test('an absent file is absent, with nothing to explain', () async {
    final read = await readJsonObjectFile(at('none.json'));
    expect(read, isA<JsonFileAbsent>());
    expect(read.object, isNull);
    expect(read.failure, isNull);
  });

  test('a directory where the file should be is unreadable, and says so', () async {
    Directory(at('auth.json')).createSync();
    final read = await readJsonObjectFile(at('auth.json'));
    expect(read, isA<JsonFileUnreadable>());
    expect(read.failure, contains('Could not read'));
    expect(read.failure, contains('auth.json'));
  });

  test('text that is not JSON is malformed, with the parser\'s reason', () async {
    File(at('auth.json')).writeAsStringSync('{"tokens": ');
    final read = await readJsonObjectFile(at('auth.json'));
    expect(read, isA<JsonFileMalformed>());
    expect(read.failure, contains('is not valid JSON'));
  });

  test('JSON that is not an object is named as such', () async {
    File(at('auth.json')).writeAsStringSync('[1, 2]');
    final read = await readJsonObjectFile(at('auth.json'));
    expect(read, isA<JsonFileNotAnObject>());
    expect(read.failure, contains('does not contain a JSON object'));
  });

  test('an object is found, with nothing to explain', () async {
    File(at('auth.json')).writeAsStringSync('{"a": 1}');
    final read = await readJsonObjectFile(at('auth.json'));
    expect(read.object, {'a': 1});
    expect(read.failure, isNull);
  });
}
