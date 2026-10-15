import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/system/windows_accessibility.dart';

/// **Screen reader support on Windows** (2026-10-15): off by default, since
/// the Flutter engine's Windows accessibility bridge can crash the app while a
/// screen reader or the touch keyboard reads it; on, the runner answers them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the setting', () {
    test('is off by default, and for a file written before it existed', () {
      expect(const Settings().windowsAccessibility, isFalse);
      expect(
        Settings.fromJson(const {'keepAwake': true}).windowsAccessibility,
        isFalse,
      );
    });

    test('survives a round trip', () {
      const on = Settings(windowsAccessibility: true);
      expect(Settings.fromJson(on.toJson()).windowsAccessibility, isTrue);
      expect(on.copyWith().windowsAccessibility, isTrue);
      expect(on, isNot(const Settings()));
    });
  });

  group('the guard', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(kWindowsAccessibilityChannel, (call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(kWindowsAccessibilityChannel, null);
    });

    test('tells the runner each change, once', () async {
      final guard = WindowsAccessibilityGuard(onWindows: true);
      await guard.apply(allowed: false);
      await guard.apply(allowed: false);
      await guard.apply(allowed: true);
      await guard.apply(allowed: true);
      expect(calls.map((c) => (c.method, c.arguments)), [
        ('setAllowed', false),
        ('setAllowed', true),
      ]);
    });

    test('says nothing off Windows', () async {
      final guard = WindowsAccessibilityGuard(onWindows: false);
      await guard.apply(allowed: true);
      expect(calls, isEmpty);
    });

    test(
      'a runner without the channel is not an error, and is retried',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(kWindowsAccessibilityChannel, null);
        final guard = WindowsAccessibilityGuard(onWindows: true);
        await guard.apply(allowed: true);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(kWindowsAccessibilityChannel, (
              call,
            ) async {
              calls.add(call);
              return null;
            });
        await guard.apply(allowed: true);
        expect(calls.map((c) => c.arguments), [true]);
      },
    );
  });
}
