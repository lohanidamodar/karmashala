import 'dart:async';

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/notes/application/composer_draft.dart';
import 'package:karmashala/src/features/sessions/presentation/message_composer.dart';
import 'package:karmashala_ui/theme.dart';

/// A file queued for a composer is **pulled** by it, and only when it can
/// attach it at once: a composer that is disabled or mid-send leaves the file
/// queued — the user was already told it was sent to the box — and takes it
/// the moment it can.
void main() {
  const shot = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\demo\shot.png',
  );

  late ProviderContainer container;
  late ValueNotifier<int> waiting;
  late ValueNotifier<bool> enabled;

  /// The transcript view's wiring, minus the transcript: the queue's ticks
  /// become [waiting], and taking is the queue's own `take`.
  Future<void> pump(
    WidgetTester tester, {
    Future<void> Function(String text)? onSend,
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    container = ProviderContainer();
    addTearDown(container.dispose);
    waiting = ValueNotifier(0);
    addTearDown(waiting.dispose);
    enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    container.listen(composerAttachmentsProvider, (_, next) {
      if (next.containsKey('s1')) waiting.value++;
    });
    List<String> take() => [
      for (final file
          in container.read(composerAttachmentsProvider.notifier).take('s1') ??
              const <EnvironmentPath>[])
        file.path,
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              ValueListenableBuilder<bool>(
                valueListenable: enabled,
                builder: (context, on, _) => MessageComposer(
                  hintText: 'Message',
                  enabled: on,
                  onSend: onSend ?? (_) async {},
                  takeServerFiles: take,
                  serverFilesWaiting: waiting,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  List<EnvironmentPath>? queued() =>
      container.read(composerAttachmentsProvider)['s1'];

  testWidgets('an able composer takes a queued file and attaches it', (
    tester,
  ) async {
    await pump(tester);

    container.read(composerAttachmentsProvider.notifier).queue('s1', shot);
    await tester.pump();

    expect(queued(), isNull, reason: 'taken means attached');
    expect(find.byTooltip('Remove'), findsOneWidget);
  });

  testWidgets('a disabled composer leaves the file queued, and takes it once '
      'enabled', (tester) async {
    await pump(tester);
    enabled.value = false;
    await tester.pump();

    container.read(composerAttachmentsProvider.notifier).queue('s1', shot);
    await tester.pump();

    expect(queued(), [shot], reason: 'refused would have been lost');
    expect(find.byTooltip('Remove'), findsNothing);

    enabled.value = true;
    await tester.pump();
    await tester.pump();

    expect(queued(), isNull);
    expect(find.byTooltip('Remove'), findsOneWidget);
  });

  testWidgets('a file queued while a message sends waits, and lands when the '
      'send ends', (tester) async {
    final sending = Completer<void>();
    await pump(tester, onSend: (_) => sending.future);
    await tester.enterText(find.byType(TextField), 'look');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    container.read(composerAttachmentsProvider.notifier).queue('s1', shot);
    await tester.pump();

    expect(queued(), [shot], reason: 'busy: not taken, so not lost');

    sending.complete();
    await tester.pump();
    await tester.pump();

    expect(queued(), isNull);
    expect(find.byTooltip('Remove'), findsOneWidget);
  });

  testWidgets('a file queued before the composer mounts is taken when it '
      'does', (tester) async {
    // The file waits behind a disabled composer, which then goes away — the
    // transcript view unmounting it — and a new one mounts with no tick.
    await pump(tester);
    enabled.value = false;
    await tester.pump();
    container.read(composerAttachmentsProvider.notifier).queue('s1', shot);
    await tester.pump();
    expect(queued(), [shot]);

    // A new composer, able from its first frame.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              MessageComposer(
                hintText: 'Message',
                onSend: (_) async {},
                takeServerFiles: () => [
                  for (final file
                      in container
                              .read(composerAttachmentsProvider.notifier)
                              .take('s1') ??
                          const <EnvironmentPath>[])
                    file.path,
                ],
                serverFilesWaiting: waiting,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(queued(), isNull);
    expect(find.byTooltip('Remove'), findsOneWidget);
  });
}
