import 'package:karmashala/src/features/browser/domain/browser_key.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every key names a DOM key, a code and a virtual key code', () {
    for (final key in kBrowserKeys) {
      expect(key.name, isNotEmpty);
      expect(key.key, isNotEmpty);
      expect(key.code, isNotEmpty);
      expect(key.virtualKeyCode, greaterThan(0));
    }
  });

  test('names are unique', () {
    final names = kBrowserKeys.map((k) => k.name).toSet();
    expect(names, hasLength(kBrowserKeys.length));
  });

  test('parses case- and separator-insensitively', () {
    for (final spelling in [
      'arrowDown',
      'ArrowDown',
      'arrow-down',
      'ARROW_DOWN',
    ]) {
      expect(parseBrowserKey(spelling)?.name, 'arrowDown', reason: spelling);
    }
  });

  test('unknown keys and null are not guessed at', () {
    expect(parseBrowserKey('f13'), isNull);
    expect(parseBrowserKey(null), isNull);
    expect(parseBrowserKey(''), isNull);
  });

  test('Enter carries the carriage return that makes it insert', () {
    final enter = parseBrowserKey('enter')!;
    expect(enter.params('keyDown')['text'], '\r');
    expect(enter.params('keyDown')['windowsVirtualKeyCode'], 13);
  });

  test('a keyUp inserts nothing, or the character would be typed twice', () {
    expect(
      parseBrowserKey('space')!.params('keyUp').containsKey('text'),
      isFalse,
    );
    expect(parseBrowserKey('space')!.params('keyDown')['text'], ' ');
  });

  test('keys that insert nothing carry no text at all', () {
    expect(
      parseBrowserKey('escape')!.params('keyDown').containsKey('text'),
      isFalse,
    );
  });

  test('the error message can list every valid name', () {
    expect(browserKeyNames, contains('arrowDown'));
    expect(browserKeyNames, contains('enter'));
  });
}
