/// The one browser's controller against a disk with no disk: what New folder
/// leaves selected or open, what a re-list keeps, and that a refusal is a
/// sentence beside a listing that still says what is there.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/picking.dart';

/// A source over a map of folder to entries, which New folder writes into.
BrowseSource _source(Map<String, List<BrowsedEntry>> tree) => BrowseSource(
  id: 'box',
  label: 'box',
  home: () async => '/home/me',
  lister: (path) async => [...?tree[path]],
  createDirectory: (directory, name) async {
    final path = '$directory/$name';
    final here = tree.putIfAbsent(directory, () => []);
    if (here.any((entry) => entry.name == name)) {
      throw StateError('There is already something called "$name" here.');
    }
    here.add(BrowsedEntry(name: name, path: path, isDirectory: true));
    tree[path] = [];
    return path;
  },
);

void main() {
  late Map<String, List<BrowsedEntry>> tree;

  setUp(() {
    tree = {
      '/home/me': [
        const BrowsedEntry(
          name: 'notes.md',
          path: '/home/me/notes.md',
          isDirectory: false,
        ),
      ],
    };
  });

  test('a new folder in the Files tab is listed and selected', () async {
    final browser = FileBrowserController(
      sources: [_source(tree)],
      multiSelect: true,
    );
    addTearDown(browser.dispose);
    await browser.start();

    final made = await browser.createFolder('work');

    expect(made, '/home/me/work');
    expect(browser.directory, '/home/me');
    expect([for (final e in browser.entries) e.name], ['work', 'notes.md']);
    expect(browser.selected, {'/home/me/work'});
    expect(browser.notice, isNull);
  });

  test('a new folder in a folder picker is walked into, so Choose answers '
      'it', () async {
    final browser = FileBrowserController(
      sources: [_source(tree)],
      directoriesOnly: true,
    );
    addTearDown(browser.dispose);
    await browser.start();

    await browser.createFolder('work');

    expect(browser.directory, '/home/me/work');
    expect(browser.answer, '/home/me/work');
  });

  test('a name already taken is a notice, and the listing stays', () async {
    final browser = FileBrowserController(
      sources: [_source(tree)],
      multiSelect: true,
    );
    addTearDown(browser.dispose);
    await browser.start();
    await browser.createFolder('work');

    final made = await browser.createFolder('work');

    expect(made, isNull);
    expect(browser.notice, contains('already something called "work"'));
    expect(browser.entries, hasLength(2));
  });

  test('a re-list keeps the selection that is still there', () async {
    final browser = FileBrowserController(
      sources: [_source(tree)],
      multiSelect: true,
    );
    addTearDown(browser.dispose);
    await browser.start();
    browser.select(browser.entries.single);

    tree['/home/me']!.add(
      const BrowsedEntry(
        name: 'added.txt',
        path: '/home/me/added.txt',
        isDirectory: false,
      ),
    );
    await browser.relist();

    expect(browser.entries, hasLength(2));
    expect(browser.selected, {'/home/me/notes.md'});
  });

  test('up from a POSIX folder reaches its root', () async {
    final browser = FileBrowserController(sources: [_source(tree)]);
    addTearDown(browser.dispose);
    await browser.start();

    browser.up();
    await pumpEventQueue();
    expect(browser.directory, '/home');
    browser.up();
    await pumpEventQueue();
    expect(browser.directory, '/');
    expect(browser.canGoUp, isFalse);
  });
}
