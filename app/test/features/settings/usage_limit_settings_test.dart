import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/settings/domain/usage_limit_settings.dart';

void main() {
  test('resumes automatically by default, and says "continue"', () {
    const settings = Settings();
    expect(settings.usageLimitBehavior, UsageLimitBehavior.schedule);
    expect(settings.resumeMessage, 'continue');
    expect(settings.resumeMessageFor('codex'), 'continue');
  });

  test('survives a JSON round-trip', () {
    final settings = const Settings()
        .copyWith(
          usageLimitBehavior: UsageLimitBehavior.ask,
          resumeMessage: 'carry on',
        )
        .withResumeMessage('codex', 'keep going');
    final json = settings.toJson();
    expect(json[kUsageLimitSettingKey], 'ask');
    expect(json.containsKey(kLegacyUsageLimitSettingKey), isFalse);
    final restored = Settings.fromJson(json);
    expect(restored, settings);
    expect(restored.resumeMessageFor('codex'), 'keep going');
    expect(restored.resumeMessageFor('claudeCode'), 'carry on');
  });

  test('absent or unknown keys read back as the defaults', () {
    expect(
      Settings.fromJson(const {}).usageLimitBehavior,
      UsageLimitBehavior.schedule,
    );
    final restored = Settings.fromJson(const {kUsageLimitSettingKey: 'later'});
    expect(restored.usageLimitBehavior, UsageLimitBehavior.schedule);
    expect(restored.resumeMessage, 'continue');
  });

  test('the legacy key: its "ask" was the old default saved on every write, '
      'so it reads as automatic; its "nothing" is kept', () {
    UsageLimitBehavior legacy(String value) => Settings.fromJson({
      kLegacyUsageLimitSettingKey: value,
    }).usageLimitBehavior;
    expect(legacy('ask'), UsageLimitBehavior.schedule);
    expect(legacy('schedule'), UsageLimitBehavior.schedule);
    expect(legacy('nothing'), UsageLimitBehavior.nothing);
    // Once saved, the new key is what speaks, even for "ask".
    expect(
      Settings.fromJson(const {
        kLegacyUsageLimitSettingKey: 'nothing',
        kUsageLimitSettingKey: 'ask',
      }).usageLimitBehavior,
      UsageLimitBehavior.ask,
    );
  });

  test('an empty remembered message means resume without a word', () {
    final settings = const Settings().withResumeMessage('codex', '');
    expect(settings.resumeMessageFor('codex'), '');
  });

  test('each participates in equality', () {
    const base = Settings();
    expect(
      base.copyWith(usageLimitBehavior: UsageLimitBehavior.nothing),
      isNot(base),
    );
    expect(base.copyWith(resumeMessage: 'go'), isNot(base));
    expect(base.withResumeMessage('codex', 'go'), isNot(base));
    expect(base.copyWith(continueInterruptedTurns: false), isNot(base));
  });

  test('continuing interrupted turns is on unless switched off', () {
    expect(const Settings().continueInterruptedTurns, isTrue);
    expect(Settings.fromJson(const {}).continueInterruptedTurns, isTrue);
    final off = const Settings().copyWith(continueInterruptedTurns: false);
    expect(off.toJson()['continueInterruptedTurns'], false);
    expect(Settings.fromJson(off.toJson()).continueInterruptedTurns, isFalse);
  });
}
