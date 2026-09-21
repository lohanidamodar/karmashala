import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/picking.dart';

/// A disk with no disk: a map of directory to its entries.
DirectoryLister _disk(Map<String, List<BrowsedEntry>> tree) =>
    (path) async =>
        tree[path] ?? (throw PathNotFoundException(path, const OSError()));

BrowsedEntry _dir(String parent, String name) =>
    BrowsedEntry(name: name, path: '$parent\\$name', isDirectory: true);

BrowsedEntry _file(String parent, String name, {bool hidden = false}) =>
    BrowsedEntry(
      name: name,
      path: '$parent\\$name',
      isDirectory: false,
      hidden: hidden || name.startsWith('.'),
    );

Future<String?> _show(
  WidgetTester tester, {
  required bool directories,
  required DirectoryLister lister,
  String startAt = r'C:\start',
  List<XTypeGroup> acceptedTypeGroups = const [],
}) async {
  String? answer;
  var done = false;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            answer = await showFileBrowser(
              context,
              what: 'a thing',
              directories: directories,
              startAt: startAt,
              acceptedTypeGroups: acceptedTypeGroups,
              lister: lister,
              exists: (_) async => false,
              environment: const {'USERPROFILE': r'C:\Users\me'},
            );
            done = true;
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return done ? answer : null;
}

IconButton _up(WidgetTester tester) => tester.widget<IconButton>(
  find.widgetWithIcon(IconButton, AppIcons.arrowUp),
);

void main() {
  const start = r'C:\start';

  // The preference is one static answer for every browser in the app, so a
  // suite that flips it must hand it back.
  setUp(HiddenFilesPreference.reset);
  tearDown(HiddenFilesPreference.reset);

  testWidgets('lists the starting folder, folders above files', (tester) async {
    await _show(
      tester,
      directories: false,
      lister: _disk({
        start: [
          _file(start, 'zeta.txt'),
          _dir(start, 'omega'),
          _file(start, 'alpha.txt'),
          _dir(start, 'beta'),
        ],
      }),
    );

    final rows = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((tile) => ((tile.title as Text).data)!)
        .toList();
    expect(rows, ['beta', 'omega', 'alpha.txt', 'zeta.txt']);
  });

  testWidgets('a folder picker offers no files at all', (tester) async {
    await _show(
      tester,
      directories: true,
      lister: _disk({
        start: [_file(start, 'alpha.txt'), _dir(start, 'beta')],
      }),
    );
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('alpha.txt'), findsNothing);
  });

  testWidgets('only the accepted extensions are offered', (tester) async {
    await _show(
      tester,
      directories: false,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Executables', extensions: ['exe']),
      ],
      lister: _disk({
        start: [
          _file(start, 'code.exe'),
          _file(start, 'notes.txt'),
          _file(start, 'noextension'),
          _dir(start, 'tools'),
        ],
      }),
    );
    expect(find.text('code.exe'), findsOneWidget);
    expect(find.text('tools'), findsOneWidget, reason: 'folders always show');
    expect(find.text('notes.txt'), findsNothing);
    expect(find.text('noextension'), findsNothing);
  });

  testWidgets('an extension match ignores case', (tester) async {
    await _show(
      tester,
      directories: false,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Builds', extensions: ['APK']),
      ],
      lister: _disk({
        start: [_file(start, 'app-release.apk')],
      }),
    );
    expect(find.text('app-release.apk'), findsOneWidget);
  });

  testWidgets('choosing a folder answers where the browser stands', (
    tester,
  ) async {
    String? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => answer = await showFileBrowser(
              context,
              what: 'a folder',
              directories: true,
              startAt: start,
              lister: _disk({start: const []}),
              exists: (_) async => false,
              environment: const {'USERPROFILE': r'C:\Users\me'},
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    expect(answer, start);
  });

  testWidgets('an empty folder still says it can be chosen', (tester) async {
    await _show(tester, directories: true, lister: _disk({start: const []}));
    expect(
      find.textContaining('You can still choose this one'),
      findsOneWidget,
    );
  });

  testWidgets('a file picker will not confirm until a file is picked', (
    tester,
  ) async {
    await _show(
      tester,
      directories: false,
      lister: _disk({
        start: [_dir(start, 'tools'), _file(start, 'alpha.txt')],
      }),
    );

    FilledButton choose() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Choose'),
    );
    expect(choose().onPressed, isNull, reason: 'nothing picked yet');

    await tester.tap(find.text('alpha.txt'));
    await tester.pumpAndSettle();
    expect(choose().onPressed, isNotNull);
  });

  testWidgets('opening a folder lists it and Up comes back', (tester) async {
    const inner = r'C:\start\tools';
    await _show(
      tester,
      directories: true,
      lister: _disk({
        start: [_dir(start, 'tools')],
        inner: [_dir(inner, 'bin')],
      }),
    );

    await tester.tap(find.text('tools'));
    await tester.pumpAndSettle();
    expect(find.text('bin'), findsOneWidget);

    await tester.tap(find.byTooltip('Up one folder'));
    await tester.pumpAndSettle();
    expect(find.text('tools'), findsOneWidget);
  });

  testWidgets('a folder that refuses is a sentence, not an exception', (
    tester,
  ) async {
    await _show(
      tester,
      directories: false,
      lister: (path) async =>
          throw PathAccessException(path, const OSError(), 'denied'),
    );
    expect(find.textContaining('would not let this app read'), findsOneWidget);
  });

  testWidgets('a folder that never answers times out and says so', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFileBrowser(
              context,
              what: 'a thing',
              directories: true,
              startAt: r'\\wsl.localhost\gone\home',
              lister: (_) => Completer<List<BrowsedEntry>>().future,
              exists: (_) async => false,
              environment: const {'USERPROFILE': r'C:\Users\me'},
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(find.byType(InlineSpinner), findsOneWidget);

    await tester.pump(kListingPatience + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.textContaining('did not answer within'), findsOneWidget);
    expect(
      find.byType(InlineSpinner),
      findsNothing,
      reason: 'a dead share costs a sentence, not a spinner forever',
    );
  });

  testWidgets('the filter narrows the listing without re-reading it', (
    tester,
  ) async {
    var reads = 0;
    final tree = {
      start: [
        _file(start, 'alpha.txt'),
        _file(start, 'beta.txt'),
        _file(start, 'gamma.txt'),
      ],
    };
    await _show(
      tester,
      directories: false,
      lister: (path) async {
        reads++;
        return tree[path] ?? const [];
      },
    );
    expect(reads, 1);

    await tester.enterText(find.byType(TextField).last, 'bet');
    await tester.pumpAndSettle();

    expect(find.text('beta.txt'), findsOneWidget);
    expect(find.text('alpha.txt'), findsNothing);
    expect(reads, 1, reason: 'filtering is not a new listing');
  });

  testWidgets('a typed path is read', (tester) async {
    const other = r'D:\elsewhere';
    await _show(
      tester,
      directories: true,
      lister: _disk({
        start: [_dir(start, 'tools')],
        other: [_dir(other, 'found-me')],
      }),
    );

    await tester.enterText(find.byType(TextField).first, other);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('found-me'), findsOneWidget);
  });

  testWidgets('Up is refused at a drive root', (tester) async {
    await _show(
      tester,
      directories: true,
      startAt: r'C:\',
      lister: _disk({r'C:\': const []}),
    );
    expect(_up(tester).onPressed, isNull);
  });

  testWidgets('Up is refused at a UNC share root', (tester) async {
    const share = r'\\wsl.localhost\archlinux';
    await _show(
      tester,
      directories: true,
      startAt: share,
      lister: _disk({share: const []}),
    );
    expect(
      _up(tester).onPressed,
      isNull,
      reason: 'the parent of a share is the Network node',
    );
  });

  testWidgets('a slow listing cannot overwrite the folder opened after it', (
    tester,
  ) async {
    const slow = r'C:\slow';
    final held = Completer<List<BrowsedEntry>>();
    await _show(
      tester,
      directories: true,
      startAt: slow,
      lister: (path) async {
        if (path == slow) return held.future;
        return [_dir(path, 'fresh')];
      },
    );

    await tester.enterText(find.byType(TextField).first, r'C:\fast');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('fresh'), findsOneWidget);

    held.complete([_dir(slow, 'stale')]);
    await tester.pumpAndSettle();
    expect(find.text('stale'), findsNothing);
    expect(find.text('fresh'), findsOneWidget);
  });
  testWidgets('Back and Forward walk the trail, and are off at its ends', (
    tester,
  ) async {
    const inner = r'C:\start\tools';
    const deeper = r'C:\start\tools\bin';
    await _show(
      tester,
      directories: true,
      lister: _disk({
        start: [_dir(start, 'tools')],
        inner: [_dir(inner, 'bin')],
        deeper: [_dir(deeper, 'deep')],
      }),
    );

    IconButton button(IconData icon) =>
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

    expect(button(AppIcons.caretLeft).onPressed, isNull, reason: 'nowhere yet');
    expect(button(AppIcons.caretRight).onPressed, isNull);

    await tester.tap(find.text('tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('bin'));
    await tester.pumpAndSettle();
    expect(find.text('deep'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('bin'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('tools'), findsOneWidget);
    expect(button(AppIcons.caretLeft).onPressed, isNull, reason: 'at the end');

    await tester.tap(find.byTooltip('Forward'));
    await tester.pumpAndSettle();
    expect(find.text('bin'), findsOneWidget);
  });

  testWidgets('opening a folder after Back drops what was ahead', (
    tester,
  ) async {
    const inner = r'C:\start\tools';
    const other = r'C:\start\other';
    await _show(
      tester,
      directories: true,
      lister: _disk({
        start: [_dir(start, 'tools'), _dir(start, 'other')],
        inner: [_dir(inner, 'bin')],
        other: [_dir(other, 'elsewhere')],
      }),
    );

    await tester.tap(find.text('tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('other'));
    await tester.pumpAndSettle();
    expect(find.text('elsewhere'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, AppIcons.caretRight),
          )
          .onPressed,
      isNull,
      reason: 'the branch that was ahead is gone, not still offered',
    );
  });
  testWidgets('hidden entries are out of sight until the chip is on', (
    tester,
  ) async {
    await _show(
      tester,
      directories: false,
      lister: _disk({
        start: [
          _file(start, 'visible.txt'),
          _file(start, '.env'),
          _file(start, 'desktop.ini', hidden: true),
        ],
      }),
    );

    expect(find.text('visible.txt'), findsOneWidget);
    expect(find.text('.env'), findsNothing);
    expect(
      find.text('desktop.ini'),
      findsNothing,
      reason: 'the Windows hidden attribute counts as well as a leading dot',
    );
    expect(find.text('Hidden (2)'), findsOneWidget, reason: 'and it says so');

    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();

    expect(find.text('.env'), findsOneWidget);
    expect(find.text('desktop.ini'), findsOneWidget);
    expect(
      find.text('Hidden'),
      findsOneWidget,
      reason: 'nothing left to count',
    );
  });

  testWidgets('a folder of nothing but hidden files says why it looks empty', (
    tester,
  ) async {
    await _show(
      tester,
      directories: false,
      lister: _disk({
        start: [_file(start, '.gitignore'), _file(start, '.env')],
      }),
    );
    expect(find.text('Hidden (2)'), findsOneWidget);
  });

  testWidgets('the hidden toggle filters, it does not re-read the folder', (
    tester,
  ) async {
    var reads = 0;
    await _show(
      tester,
      directories: false,
      lister: (path) async {
        reads++;
        return [_file(path, 'seen.txt'), _file(path, '.unseen')];
      },
    );
    expect(reads, 1);

    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    expect(find.text('.unseen'), findsOneWidget);
    expect(reads, 1);
  });
}
