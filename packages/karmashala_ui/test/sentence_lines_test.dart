import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/transcript.dart';

void main() {
  test('each sentence of a paragraph starts a line, as a hard break', () {
    expect(
      oneSentencePerLine('It fails. The guard runs first! Why? Nobody knows.'),
      'It fails.\\\nThe guard runs first!\\\nWhy?\\\nNobody knows.',
    );
  });

  test('abbreviations, initials and a lowercase word keep the sentence', () {
    const text = 'Use a tool, e.g. Python. Ask J. Smith about approx. ten.';
    expect(
      oneSentencePerLine(text),
      'Use a tool, e.g. Python.\\\nAsk J. Smith about approx. ten.',
    );
    expect(
      oneSentencePerLine('Version 2. then more.'),
      'Version 2. then more.',
    );
  });

  test('code, links, headings and tables are left whole', () {
    const text =
        '# Done. Next.\n'
        '| a. B | c |\n'
        '```\n'
        'one. Two.\n'
        '```\n'
        'Run `a. B` now. See [one. Two](x).';
    expect(
      oneSentencePerLine(text),
      '# Done. Next.\n'
      '| a. B | c |\n'
      '```\n'
      'one. Two.\n'
      '```\n'
      'Run `a. B` now.\\\n'
      'See [one. Two](x).',
    );
  });

  test('a list item and a quote keep their lines inside them', () {
    expect(
      oneSentencePerLine('- First. Second.\n> Quoted. Again.'),
      '- First.\\\n  Second.\n> Quoted.\\\n> Again.',
    );
    expect(oneSentencePerLine('12. One. Two.'), '12. One.\\\n    Two.');
  });

  test('one sentence is returned as it came', () {
    expect(oneSentencePerLine('Just one.'), 'Just one.');
    expect(oneSentencePerLine(''), '');
  });

  test('the markdown reads as one line per sentence', () {
    expect(
      markdownPlainText(oneSentencePerLine('It fails. It passes.')),
      'It fails.\nIt passes.',
    );
  });
}
