import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/settings/domain/usage_limit_settings.dart';

void main() {
  test('asks by default, and says "continue"', () {
    const settings = Settings();
    expect(settings.usageLimitBehavior, UsageLimitBehavior.ask);
    expect(settings.resumeMessage, 'continue');
    expect(settings.resumeMessageFor('codex'), 'continue');
  });

  test('survives a JSON round-trip', () {
    final settings = const Settings()
        .copyWith(
          usageLimitBehavior: UsageLimitBehavior.schedule,
          resumeMessage: 'carry on',
        )
        .withResumeMessage('codex', 'keep going');
    final restored = Settings.fromJson(settings.toJson());
    expect(restored, settings);
    expect(restored.resumeMessageFor('codex'), 'keep going');
    expect(restored.resumeMessageFor('claudeCode'), 'carry on');
  });

  test('absent or unknown keys read back as the defaults', () {
    final restored = Settings.fromJson(const {'usageLimitBehavior': 'later'});
    expect(restored.usageLimitBehavior, UsageLimitBehavior.ask);
    expect(restored.resumeMessage, 'continue');
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
  });
}
