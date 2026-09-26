import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/presentation/remote_access_section.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_providers.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_service.dart';
import 'package:karmashala/src/features/settings/presentation/settings_notice.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../support/memory_server_config.dart';

/// The one notice the settings surfaces draw under a setting.
void main() {
  Widget host(Widget child, {double width = 320}) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    ),
  );

  testWidgets('a long message wraps beside its glyph and action', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        SettingsNotice(
          tone: SettingsNoticeTone.danger,
          message:
              'Local relay: port 8787 is already in use by another program '
              'that has held it since the last time this machine started.',
          action: TextButton(onPressed: () {}, child: const Text('Retry')),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Retry'), findsOneWidget);
    expect(
      tester.getSize(find.byType(SettingsNotice)).height,
      greaterThan(40),
      reason: 'the sentence wraps rather than overflowing',
    );
  });

  testWidgets('a danger notice says it in the failure colour, glyph and text', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const SettingsNotice(
          tone: SettingsNoticeTone.danger,
          message: 'Nothing opens at this path.',
        ),
      ),
    );
    final context = tester.element(find.byType(SettingsNotice));
    final error = SemanticColors.of(context).failure;
    expect(tester.widget<Icon>(find.byType(Icon)).color, error);
    expect(
      tester
          .widget<Text>(find.text('Nothing opens at this path.'))
          .style
          ?.color,
      error,
    );
  });

  testWidgets('Remote access says "no relay" with the shared notice', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        localRelayStatusProvider.overrideWithValue(
          const LocalRelayStatus.stopped(),
        ),
      ],
    );
    addTearDown(container.dispose);
    setRemoteAccessNow(container, enabled: true);
    setRemoteAccessNow(container, hostedEnabled: false);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: host(
          const SingleChildScrollView(child: RemoteAccessSection()),
          width: 600,
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byWidgetPredicate(
        (w) =>
            w is SettingsNotice &&
            w.message.startsWith('No relay is switched on') &&
            w.tone == SettingsNoticeTone.danger,
      ),
      findsOneWidget,
    );
  });
}
