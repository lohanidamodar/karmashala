import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';

import 'explorer_fixture.dart';

/// A folder of thousands of files costs the rows on screen, not the folder.
void main() {
  const root = r'C:\big';
  const count = 5000;

  final listings = {
    root: [
      dirEntry(r'C:\big\a-dir'),
      for (var i = 0; i < count; i++)
        fileEntry('C:\\big\\file-${i.toString().padLeft(4, '0')}.txt'),
    ],
    r'C:\big\a-dir': [fileEntry(r'C:\big\a-dir\inner.txt')],
  };

  late ProviderContainer container;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    container = ProviderContainer(overrides: explorerOverrides(root, listings));
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: FileExplorerView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() => debugFileRowBuilds = 0);

  testWidgets('a large folder builds only the rows on screen', (tester) async {
    await pump(tester);

    expect(find.text('file-0000.txt'), findsOneWidget);
    expect(find.text('file-4999.txt'), findsNothing);
    expect(
      debugFileRowBuilds,
      lessThan(200),
      reason: 'every one of $count rows was built',
    );
  });

  testWidgets('a folder opens on demand and its rows are still reachable', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('inner.txt'), findsNothing);

    await tester.tap(find.text('a-dir'));
    await tester.pumpAndSettle();
    expect(find.text('inner.txt'), findsOneWidget);

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).last)
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('file-4999.txt'), findsOneWidget);
    expect(debugFileRowBuilds, lessThan(1000));
  });

  testWidgets('a reveal scrolls a far target into view', (tester) async {
    await pump(tester);

    container
        .read(fileRevealTargetProvider.notifier)
        .reveal(
          FileRevealTarget(
            path: at(r'C:\big\file-4000.txt'),
            isDirectory: false,
          ),
        );
    await tester.pumpAndSettle();

    expect(find.text('file-4000.txt'), findsOneWidget);
  });
}
