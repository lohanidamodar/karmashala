import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/transcript.dart';

void main() {
  test('markup goes, the words and their order stay', () {
    expect(
      markdownPlainText(
        '# Done\n\nA **bold** [link](https://x.dev) and `code`.\n\n'
        '- one\n  - nested\n- ![shot](a.png)\n\n'
        '1. first\n2. second\n\n'
        '| a | b |\n| - | - |\n| 1 | 2 |\n\n'
        '> quoted\n\n```dart\nfinal x = 1;\n```',
      ),
      'Done\n\n'
      'A bold link and code.\n\n'
      '- one\n  - nested\n- shot\n\n'
      '1. first\n2. second\n\n'
      'a\tb\n1\t2\n\n'
      'quoted\n\n'
      'final x = 1;',
    );
  });

  test('text with no markdown is itself', () {
    expect(markdownPlainText('Just words & more.'), 'Just words & more.');
  });
}
