import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/picking.dart';

/// Which dialog a "Browse…" opens: the user's choice, the platform's default,
/// and the one case neither gets a vote.
void main() {
  tearDown(() {
    FilePickerChoice.prefersInApp = null;
    BrowseSources.lookup = null;
  });

  BrowseSource source(String id, {required bool local}) => BrowseSource(
    id: id,
    label: id,
    local: local,
    home: () async => local ? r'C:\Users\me' : '/home/me',
    lister: (_) async => const [],
  );

  /// Runs a pick and reports whether the **host** dialog was asked for.
  Future<bool> hostDialogWasUsed(
    WidgetTester tester, {
    String? environmentId,
    bool? inApp,
  }) async {
    var asked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => pickOneFile(
              context: context,
              environmentId: environmentId,
              what: 'a thing',
              startNear: r'C:\Users\me',
              show:
                  ({
                    List<XTypeGroup> acceptedTypeGroups = const [],
                    String? confirmButtonText,
                    String? initialDirectory,
                  }) async {
                    asked = true;
                    return null;
                  },
              forget: () async => 0,
              forgetRemote: (_) async => 0,
              inApp: inApp,
            ),
            child: const Text('browse'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('browse'));
    await tester.pumpAndSettle();
    // The in-app browser arms a listing-patience timer as it opens, and it
    // used to be drained by accident: `pumpAndSettle` against a spinner that
    // asked for every vsync burned ten seconds of fake time before returning.
    // The spinner settles now, so the wait is spelled out.
    await tester.pump(kListingPatience + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    return asked;
  }

  group('FilePickerChoice', () {
    test('with nobody asked, the platform answers', () {
      expect(FilePickerChoice.inApp, FilePickerChoice.platformDefault);
    });

    test('the user outranks the platform, both ways', () {
      FilePickerChoice.prefersInApp = () => true;
      expect(FilePickerChoice.inApp, isTrue);
      FilePickerChoice.prefersInApp = () => false;
      expect(FilePickerChoice.inApp, isFalse);
    });

    test('a preference that throws costs nobody their picker', () {
      FilePickerChoice.prefersInApp = () => throw StateError('no settings yet');
      expect(FilePickerChoice.inApp, FilePickerChoice.platformDefault);
    });
  });

  group('what a Browse actually opens', () {
    testWidgets('the system dialog, when that is what was chosen', (
      tester,
    ) async {
      FilePickerChoice.prefersInApp = () => false;
      expect(await hostDialogWasUsed(tester), isTrue);
    });

    testWidgets('Karmashala\'s own, when that is what was chosen', (
      tester,
    ) async {
      FilePickerChoice.prefersInApp = () => true;
      expect(await hostDialogWasUsed(tester), isFalse);
      expect(find.byType(FileBrowserDialog), findsOneWidget);
    });

    testWidgets('a folder on another machine is never a preference', (
      tester,
    ) async {
      FilePickerChoice.prefersInApp = () => false;
      BrowseSources.lookup = () => [
        source('windows', local: true),
        source('ssh:h1', local: false),
      ];

      expect(
        await hostDialogWasUsed(tester, environmentId: 'ssh:h1'),
        isFalse,
        reason: 'no local dialog can reach a host, whatever the user picked',
      );
      expect(find.byType(FileBrowserDialog), findsOneWidget);
    });

    testWidgets('this machine still honours the choice when sources exist', (
      tester,
    ) async {
      FilePickerChoice.prefersInApp = () => false;
      BrowseSources.lookup = () => [
        source('windows', local: true),
        source('ssh:h1', local: false),
      ];
      expect(await hostDialogWasUsed(tester, environmentId: 'windows'), isTrue);
    });

    testWidgets('an environment nothing knows falls back to the choice', (
      tester,
    ) async {
      FilePickerChoice.prefersInApp = () => false;
      BrowseSources.lookup = () => [source('windows', local: true)];
      expect(
        await hostDialogWasUsed(tester, environmentId: 'retired'),
        isTrue,
        reason: 'an id nothing matches is no evidence that it is remote',
      );
    });

    testWidgets('a caller with no choice to offer is obeyed', (tester) async {
      // The device pane passes this: the host dialog has never once drawn
      // there, whatever the registry held.
      FilePickerChoice.prefersInApp = () => false;
      expect(await hostDialogWasUsed(tester, inApp: true), isFalse);
      expect(find.byType(FileBrowserDialog), findsOneWidget);
    });
  });
}
