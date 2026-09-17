import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/rows.dart';

void main() {
  test(
    'a home path is written with ~, then fish-style, then its last folder',
    () {
      expect(
        abbreviatePath(
          '/Users/dlohani/Documents/projects/popupbits-ai-workspace',
        ),
        [
          '~/Documents/projects/popupbits-ai-workspace',
          '~/D/p/popupbits-ai-workspace',
          '…/popupbits-ai-workspace',
        ],
      );
      expect(abbreviatePath('/home/dev/src/app'), [
        '~/src/app',
        '~/s/app',
        '…/app',
      ]);
    },
  );

  test('the last folder is never cut, on any candidate', () {
    for (final candidate in abbreviatePath('/srv/builds/nightly/karmashala')) {
      expect(candidate, endsWith('karmashala'));
    }
  });

  test('a Windows path keeps its drive and its separator', () {
    expect(abbreviatePath(r'C:\src\clients\demo'), [
      r'C:\src\clients\demo',
      r'C:\s\c\demo',
      r'…\demo',
    ]);
    expect(abbreviatePath(r'C:\Users\me\work\hub'), [
      r'~\work\hub',
      r'~\w\hub',
      r'…\hub',
    ]);
  });

  test('a path outside any home keeps its root', () {
    expect(abbreviatePath('/srv/www/site'), [
      '/srv/www/site',
      '/s/w/site',
      '…/site',
    ]);
  });

  test('a hidden parent keeps its dot', () {
    expect(abbreviatePath('/Users/me/.config/nvim')[1], '~/.c/nvim');
  });

  test('a path with nothing to cut is said once', () {
    expect(abbreviatePath('/Users/me'), ['~']);
    expect(abbreviatePath('/Users/me/hub'), ['~/hub', '…/hub']);
    expect(abbreviatePath('hub'), ['hub']);
    expect(abbreviatePath(''), isEmpty);
    expect(abbreviatePath('/'), ['/']);
  });

  test('a user folder named like another is not mistaken for home', () {
    expect(abbreviatePath('/Users').first, '/Users');
    expect(abbreviatePath('/Usersx/me/app').first, '/Usersx/me/app');
  });
}
