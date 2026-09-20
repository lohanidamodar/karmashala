import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/widgets.dart';

import 'fake_scrcpy_control_channel.dart';

/// The two clipboard buttons: which one is off, why it says it is off, and what
/// the user is told when the device would not answer.
///
/// The last of those is the reason this file exists. Everything else on the
/// device control row works over `adb shell`; the clipboard does not, so a
/// clipboard button is off in exactly the situation where the rest of the row
/// still works — and a greyed-out icon with no sentence reads as a bug in the
/// app rather than a missing transport.
void main() {
  late FakeScrcpyControlChannel channel;
  late FakeHostClipboard host;
  late List<String> said;

  setUp(() {
    channel = FakeScrcpyControlChannel();
    host = FakeHostClipboard();
    said = [];
  });

  tearDown(() => channel.dispose());

  DeviceClipboardBridge bridge({Duration? timeout}) => DeviceClipboardBridge(
    channel: channel,
    host: host,
    timeout: timeout ?? Duration.zero,
  );

  Future<void> pump(WidgetTester tester, DeviceClipboardBridge? given) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DeviceControlBar(
              controls: deviceClipboardControls(bridge: given, say: said.add),
            ),
          ),
        ),
      );

  Finder toDevice() =>
      find.byKey(const ValueKey('android-clipboard-to-device'));
  Finder fromDevice() =>
      find.byKey(const ValueKey('android-clipboard-from-device'));

  testWidgets('with no control socket both buttons are off and say why', (
    tester,
  ) async {
    await pump(tester, null);
    expect(tester.widget<IconButton>(toDevice()).onPressed, isNull);
    expect(tester.widget<IconButton>(fromDevice()).onPressed, isNull);
    final tooltip = tester.widget<IconButton>(toDevice()).tooltip!;
    // The reason names the transport and the fallback that does not exist.
    expect(tooltip, contains('control socket'));
    expect(tooltip, contains('no clipboard verb'));
  });

  testWidgets('a closed socket explains itself rather than failing on press', (
    tester,
  ) async {
    channel.close();
    await pump(tester, bridge());
    expect(
      tester.widget<IconButton>(fromDevice()).tooltip,
      contains('has closed'),
    );
  });

  testWidgets('with a live socket the tooltips name the direction', (
    tester,
  ) async {
    await pump(tester, bridge());
    expect(
      tester.widget<IconButton>(toDevice()).tooltip,
      "Copy this computer's clipboard to the device",
    );
    expect(
      tester.widget<IconButton>(fromDevice()).tooltip,
      "Copy the device's clipboard to this computer",
    );
  });

  testWidgets('a device that will not answer is not reported as empty', (
    tester,
  ) async {
    // The whole feature's honesty, at the surface the user reads.
    await pump(tester, bridge());
    await tester.tap(fromDevice());
    await tester.pumpAndSettle();
    expect(said, hasLength(1));
    // It must not claim emptiness — and it says so in as many words, because
    // "could not read" is the sentence that sends the user to the right place.
    expect(said.single, isNot(contains('clipboard is empty')));
    expect(said.single, contains('it is not empty'));
    // And what the user already had here is untouched.
    expect(host.text, isNull);
  });

  testWidgets('a clipboard the device pushed is taken without asking', (
    tester,
  ) async {
    await pump(tester, bridge());
    channel.deliverClipboard('copied on the phone');
    await tester.pump();
    final before = channel.sent.length;
    await tester.tap(fromDevice());
    await tester.pumpAndSettle();
    expect(host.text, 'copied on the phone');
    expect(channel.sent.length, before, reason: 'no round trip was needed');
    // The message says how much, never what.
    expect(said.single, contains('19 characters'));
    expect(said.single, isNot(contains('copied on the phone')));
  });

  testWidgets('an empty host clipboard is refused rather than sent', (
    tester,
  ) async {
    await pump(tester, bridge());
    await tester.tap(toDevice());
    await tester.pumpAndSettle();
    expect(said.single, contains('no text on this computer'));
    expect(channel.sent, isEmpty);
  });

  testWidgets('a write the device did not confirm claims neither way', (
    tester,
  ) async {
    host.text = 'from Windows';
    await pump(tester, bridge());
    await tester.tap(toDevice());
    await tester.pumpAndSettle();
    expect(said.single, contains('may or may not'));
    expect(said.single, isNot(contains('Copied')));
  });

  testWidgets('no message ever carries the clipboard text', (tester) async {
    host.text = 'hunter2';
    await pump(tester, bridge());
    await tester.tap(toDevice());
    await tester.pumpAndSettle();
    channel.deliverClipboard('s3cret from the phone');
    await tester.pump();
    await tester.tap(fromDevice());
    await tester.pumpAndSettle();
    for (final message in said) {
      expect(message, isNot(contains('hunter2')));
      expect(message, isNot(contains('s3cret')));
    }
  });
}
