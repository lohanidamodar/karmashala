import 'package:test/test.dart';
import 'package:karmashala_devices/src/domain/android_slimming.dart';

/// Categories in one layer, as a set.
Set<AndroidSlimmingCategory> _layer(AndroidSlimmingLayer layer) =>
    AndroidSlimmingCategory.inLayer(layer).toSet();

void main() {
  group('ids', () {
    test('are unique, and are not the enum constant names', () {
      // The id is what a saved preference stores; deriving it from `name` would
      // let a rename change which categories somebody's emulator gets.
      final ids = AndroidSlimmingCategory.values.map((c) => c.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(AndroidSlimmingCategory.playServices.id, 'gms');
      expect(AndroidSlimmingCategory.passiveGps.id, 'gps');
      expect(AndroidSlimmingCategory.bundledApps.id, 'apps');
    });

    test('byId finds a category and refuses an unknown one', () {
      expect(
        AndroidSlimmingCategory.byId('gms'),
        AndroidSlimmingCategory.playServices,
      );
      expect(AndroidSlimmingCategory.byId('playServices'), isNull);
      expect(AndroidSlimmingCategory.byId(''), isNull);
    });

    test('categoriesFromIds drops ids this build no longer knows', () {
      // A category removed in a later release must not make a saved preference
      // unreadable.
      final categories = categoriesFromIds([
        'animations',
        'a-category-from-the-future',
      ]);
      expect(categories, {AndroidSlimmingCategory.animations});
    });

    test('every default id names a real category', () {
      expect(
        categoriesFromIds(kDefaultAndroidSlimming),
        hasLength(kDefaultAndroidSlimming.length),
      );
    });
  });

  group('defaults', () {
    test('apply both harmless layers and no package group', () {
      // Layer 3 is where all the memory is and the only layer that breaks apps,
      // so a user who never opens the dialog must not lose Play services.
      final defaults = categoriesFromIds(kDefaultAndroidSlimming);
      expect(defaults, containsAll(_layer(AndroidSlimmingLayer.launch)));
      expect(defaults, containsAll(_layer(AndroidSlimmingLayer.settings)));
      expect(
        defaults.intersection(_layer(AndroidSlimmingLayer.packages)),
        isEmpty,
      );
      expect(packagesFor(enabled: defaults), isEmpty);
    });
  });

  group('launchArguments', () {
    test('are the three flags confirmed against the emulator binary', () {
      expect(
        launchArguments(enabled: categoriesFromIds(kDefaultAndroidSlimming)),
        ['-no-audio', '-no-metrics', '-no-passive-gps'],
      );
    });

    test('carry nothing for a selection with no launch category', () {
      expect(
        launchArguments(enabled: {AndroidSlimmingCategory.playServices}),
        isEmpty,
      );
    });

    test('leave the renderer to the emulator on automatic', () {
      // `-gpu auto` and passing no flag differ: without the flag the AVD's own
      // `hw.gpu.mode` still applies.
      expect(AndroidGpuMode.auto.arguments, isEmpty);
      expect(launchArguments(gpu: AndroidGpuMode.auto), isEmpty);
    });

    test('append the chosen renderer last', () {
      expect(
        launchArguments(
          enabled: {AndroidSlimmingCategory.audio},
          gpu: AndroidGpuMode.host,
        ),
        ['-no-audio', '-gpu', 'host'],
      );
    });

    test('an unknown saved renderer falls back to automatic', () {
      expect(
        AndroidGpuMode.byId('vulkan-from-the-future'),
        AndroidGpuMode.auto,
      );
    });
  });

  group('settings', () {
    test('zero all three animation scales', () {
      expect(settingsArguments(enabled: {AndroidSlimmingCategory.animations}), [
        ['shell', 'settings', 'put', 'global', 'window_animation_scale', '0'],
        [
          'shell',
          'settings',
          'put',
          'global',
          'transition_animation_scale',
          '0',
        ],
        ['shell', 'settings', 'put', 'global', 'animator_duration_scale', '0'],
      ]);
    });

    test('are empty when the category is not selected', () {
      expect(
        settingsArguments(enabled: {AndroidSlimmingCategory.audio}),
        isEmpty,
      );
    });

    test('restore deletes every managed key rather than writing 1.0', () {
      // Stock Android leaves these unset and treats absent as 1.0, so deleting
      // restores what the device shipped with rather than our fingerprint.
      final restore = settingsRestoreArguments();
      expect(restore.map((c) => c[4]).toSet(), allManagedSettingsKeys);
      for (final command in restore) {
        expect(command.take(4), ['shell', 'settings', 'delete', 'global']);
      }
    });

    test('restore covers everything, not just the current selection', () {
      // A user who unticks a category and then restores must not be left with
      // exactly the setting nobody put back.
      expect(
        settingsRestoreArguments(),
        hasLength(allManagedSettingsKeys.length),
      );
    });
  });

  group('packages', () {
    test('a group yields its own packages and nothing else', () {
      final gms = packagesFor(enabled: {AndroidSlimmingCategory.playServices});
      expect(gms, contains('com.google.android.gms'));
      expect(gms, contains('com.android.vending'));
      expect(gms, isNot(contains('com.google.android.youtube')));
    });

    test('the allowlist never reaches anything the system needs', () {
      // The safety mechanism: `pm` is only ever handed a name from this table.
      // The keyboard one matters most, because this pane types through it.
      const forbidden = [
        'android',
        'com.android.systemui',
        'com.android.settings',
        'com.android.shell',
        'com.android.providers.settings',
        'com.android.providers.contacts',
        'com.android.providers.media',
        'com.android.chrome',
        'com.google.android.webview',
        'com.google.android.apps.nexuslauncher',
        'com.google.android.inputmethod.latin',
        'com.google.android.marvin.talkback',
        'com.google.android.permissioncontroller',
        'com.google.android.packageinstaller',
        'com.google.android.contacts',
        'com.google.android.dialer',
      ];
      for (final package in forbidden) {
        expect(
          allManagedPackages,
          isNot(contains(package)),
          reason: '$package must never be disabled by this build',
        );
      }
    });

    test('disable and enable are exact inverses', () {
      expect(disableArgumentsFor('com.google.android.gms'), [
        'shell',
        'pm',
        'disable-user',
        '--user',
        '0',
        'com.google.android.gms',
      ]);
      expect(enableArgumentsFor('com.google.android.gms'), [
        'shell',
        'pm',
        'enable',
        '--user',
        '0',
        'com.google.android.gms',
      ]);
    });

    test('neither will touch a package outside the allowlist', () {
      // The allowlist is enforced where the command is built, not trusted at
      // the caller, so a stale saved id cannot reach `pm`.
      expect(disableArgumentsFor('com.android.systemui'), isEmpty);
      expect(enableArgumentsFor('com.android.systemui'), isEmpty);
    });

    test('every managed package is claimed by a package-layer category', () {
      for (final package in allManagedPackages) {
        final owners = [
          for (final category in AndroidSlimmingCategory.values)
            if (category.packages.contains(package)) category,
        ];
        expect(owners, isNotEmpty);
        for (final owner in owners) {
          expect(owner.layer, AndroidSlimmingLayer.packages);
        }
      }
    });
  });

  group('feature loss', () {
    test('is reported only for what is about to happen', () {
      expect(featureLossFor(), isEmpty);
      final losses = featureLossFor(
        enabled: {AndroidSlimmingCategory.playServices},
      );
      expect(losses.keys, contains('com.google.android.gms'));
      expect(losses['com.google.android.gms'], contains('Firebase'));
      expect(losses.keys, isNot(contains('-no-audio')));
    });

    test('the two durable layers say so, and the flags do not', () {
      expect(AndroidSlimmingLayer.launch.persists, isFalse);
      expect(AndroidSlimmingLayer.settings.persists, isTrue);
      expect(AndroidSlimmingLayer.packages.persists, isTrue);
      for (final layer in AndroidSlimmingLayer.values) {
        expect(layer.note, isNotEmpty);
      }
    });
  });
}
