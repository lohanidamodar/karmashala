import 'dart:convert';

import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:test/test.dart';

/// Whether turns are checkpointed and how many are kept: the preference a
/// client writes and the server's recorder reads.
void main() {
  test('nothing written is automatic, keeping the default', () {
    final none = CheckpointSettings.fromJson(null);
    expect(none.automatic, isTrue);
    expect(none.keepPerRepository, kDefaultCheckpointRetention);
    expect(CheckpointSettings.fromJson('junk').automatic, isTrue);
    expect(kCheckpointSettingsKey, 'checkpoints.settings.v1');
  });

  test('what is written reads back, "keep all" included', () {
    final off = const CheckpointSettings()
        .copyWith(automatic: false)
        .copyWith(keep: () => null);
    final back = CheckpointSettings.fromJson(
      jsonDecode(jsonEncode(off.toJson())),
    );
    expect(back.automatic, isFalse);
    expect(back.keepPerRepository, isNull);
    final fifty = CheckpointSettings.fromJson(
      jsonDecode(
        jsonEncode(
          const CheckpointSettings().copyWith(keep: () => 50).toJson(),
        ),
      ),
    );
    expect(fifty.keepPerRepository, 50);
  });

  test('a limit out of shape keeps everything; a missing one the default', () {
    expect(
      CheckpointSettings.fromJson({'keepPerRepository': -3}).keepPerRepository,
      isNull,
    );
    expect(CheckpointSettings.fromJson({'automatic': 'yes'}).automatic, isTrue);
    expect(
      CheckpointSettings.fromJson({'automatic': false}).keepPerRepository,
      kDefaultCheckpointRetention,
    );
    expect(kCheckpointRetentionChoices, contains(null));
  });

  test('a chain may grow a tenth past its limit, at least ten', () {
    expect(checkpointPruneSlack(50), 10);
    expect(checkpointPruneSlack(200), 20);
    expect(checkpointPruneSlack(500), 50);
  });
}
