import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/probe/probe_mode.dart';
import 'package:karmashala/src/features/git/application/remote_links.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/update/application/github_update_controller.dart';
import 'package:karmashala/src/features/update/application/release_feed.dart';
import 'package:karmashala/src/features/update/application/update_ports.dart';
import 'package:karmashala/src/features/update/domain/install_kind.dart';
import 'package:karmashala/src/features/update/domain/update_status.dart';

import '../../support/fake_data_server.dart';
import 'update_fakes.dart';

const _setup = 'Karmashala-Setup-1.35.0.exe';
const _appImage = 'Karmashala-1.35.0-x86_64.AppImage';
const _dmg = 'Karmashala-macOS-1.35.0.dmg';
const _apk = 'Karmashala-android-1.35.0.apk';

Uri _url(String name) => Uri.parse(
  'https://github.com/lohanidamodar/karmashala/releases/download/v1.35.0/$name',
);

void main() {
  late FakeUpdateHttp http;
  late FakeUpdateSystem system;
  late List<String> openedUrls;
  late int quits;
  final bytes = List<int>.generate(5000, (i) => i % 251);

  setUp(() {
    http = FakeUpdateHttp();
    system = FakeUpdateSystem(
      const InstallFacts(
        os: 'windows',
        namesBesideExecutable: ['karmashala.exe', 'unins000.exe'],
      ),
    );
    openedUrls = [];
    quits = 0;
  });

  Future<ProviderContainer> container({
    String version = '1.34.27',
    bool probe = false,
    UpdateSchedule schedule = const UpdateSchedule(
      firstCheck: Duration(hours: 1),
    ),
  }) async {
    final server = FakeDataServer();
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        updateHttpProvider.overrideWithValue(http),
        updateSystemProvider.overrideWithValue(system),
        runningVersionProvider.overrideWithValue(version),
        updateScheduleProvider.overrideWithValue(schedule),
        probeModeProvider.overrideWithValue(
          probe ? ProbeMode.on : ProbeMode.off,
        ),
        openExternalUrlProvider.overrideWithValue((url) async {
          openedUrls.add(url);
          return true;
        }),
        updateQuitProvider.overrideWithValue(() async => quits++),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> answerRelease({String? digest, int? size}) async {
    http.answerJson(
      releaseJson(
        assets: [
          for (final name in [_setup, _appImage, _dmg, _apk])
            assetJson(
              name,
              size ?? bytes.length,
              digest: digest ?? await digestOf(bytes),
            ),
        ],
      ),
      etag: '"abc"',
    );
    for (final name in [_setup, _appImage, _dmg, _apk]) {
      http.files[_url(name)] = bytes;
    }
  }

  GitHubUpdateController controllerOf(ProviderContainer c) =>
      c.read(githubUpdateProvider.notifier);

  test('start measures the install kind', () async {
    final c = await container();
    await controllerOf(c).start();
    expect(c.read(githubUpdateProvider).kind, InstallKind.windowsInstaller);
  });

  test('the first check runs on its own after the delay', () async {
    await answerRelease();
    final c = await container(
      schedule: const UpdateSchedule(firstCheck: Duration.zero),
    );
    await controllerOf(c).start();
    await pumpEventQueue();
    expect(http.checks, hasLength(1));
    expect(c.read(githubUpdateProvider).status, isA<UpdateAvailable>());
  });

  test(
    'an unstamped build, a probe and a Play install never check alone',
    () async {
      await answerRelease();
      const now = UpdateSchedule(firstCheck: Duration.zero);
      final unstamped = await container(version: '', schedule: now);
      await controllerOf(unstamped).start();
      final probe = await container(probe: true, schedule: now);
      await controllerOf(probe).start();
      system.facts = const InstallFacts(
        os: 'android',
        androidInstallerKnown: true,
        androidInstaller: kPlayStoreInstaller,
      );
      final play = await container(schedule: now);
      await controllerOf(play).start();
      await controllerOf(play).check(manual: true);
      await pumpEventQueue();
      expect(http.checks, isEmpty);
      expect(play.read(githubUpdateProvider).kind, InstallKind.androidPlay);
    },
  );

  test('the switch off stops automatic checks, not the manual one', () async {
    await answerRelease();
    final c = await container();
    c.read(settingsControllerProvider.notifier).setCheckForUpdates(false);
    await controllerOf(c).start();
    await controllerOf(c).check();
    expect(http.checks, isEmpty);
    await controllerOf(c).check(manual: true);
    expect(http.checks, hasLength(1));
  });

  test('an older or equal release is up to date', () async {
    await answerRelease();
    final c = await container(version: '1.35.0+95');
    await controllerOf(c).start();
    await controllerOf(c).check(manual: true);
    expect(c.read(githubUpdateProvider).status, isA<UpdateUpToDate>());
  });

  test('the second check sends the ETag and a 304 keeps the offer', () async {
    await answerRelease();
    http.answers.add(const UpdateHttpResponse(304, ''));
    final c = await container();
    await controllerOf(c).start();
    await controllerOf(c).check(manual: true);
    await controllerOf(c).check(manual: true);
    expect(http.checks.first.containsKey('if-none-match'), isFalse);
    expect(http.checks.last['if-none-match'], '"abc"');
    expect(c.read(githubUpdateProvider).status, isA<UpdateAvailable>());
  });

  test('a failed automatic check is quiet; a manual one says so', () async {
    http.answers.add(const UpdateHttpResponse(403, '{}'));
    final c = await container();
    await controllerOf(c).start();
    await controllerOf(c).check();
    expect(c.read(githubUpdateProvider).status, isA<UpdateIdle>());
    await controllerOf(c).check(manual: true);
    final failed = c.read(githubUpdateProvider).status as UpdateFailed;
    expect(failed.message, contains('hourly limit'));
    expect(failed.release, isNull);
  });

  test('Skip remembers the tag; Later hides until the next launch', () async {
    await answerRelease();
    final c = await container();
    await controllerOf(c).start();
    await controllerOf(c).check(manual: true);
    controllerOf(c).skip();
    expect(c.read(settingsControllerProvider).skippedUpdateVersion, 'v1.35.0');
    controllerOf(c).later();
    expect(c.read(githubUpdateProvider).later, isTrue);
  });

  group('Windows installer', () {
    test('downloads, verifies, then runs silently and quits', () async {
      await answerRelease();
      final c = await container();
      await controllerOf(c).start();
      await controllerOf(c).check(manual: true);
      await controllerOf(c).update();
      final ready = c.read(githubUpdateProvider).status as UpdateReady;
      expect(ready.path, '/tmp/karmashala-update/$_setup');
      expect(system.written[ready.path], bytes);
      expect(system.started, isEmpty, reason: 'not before the confirmation');
      await controllerOf(c).install();
      expect(system.started.single.$1, ready.path);
      expect(system.started.single.$2, [
        '/SILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/KARMASHALARESTART',
      ]);
      expect(quits, 1);
    });

    test('a checksum mismatch deletes the file and says so', () async {
      await answerRelease(digest: 'sha256:${'0' * 64}');
      final c = await container();
      await controllerOf(c).start();
      await controllerOf(c).check(manual: true);
      await controllerOf(c).update();
      final failed = c.read(githubUpdateProvider).status as UpdateFailed;
      expect(failed.message, contains('checksum'));
      expect(failed.message, contains('deleted'));
      expect(failed.release?.tag, 'v1.35.0');
      expect(system.deleted, ['/tmp/karmashala-update/$_setup']);
      expect(system.started, isEmpty);
    });

    test('with no digest a wrong size fails the download', () async {
      http.answerJson(
        releaseJson(assets: [assetJson(_setup, bytes.length + 1)]),
      );
      http.files[_url(_setup)] = bytes;
      final c = await container();
      await controllerOf(c).start();
      await controllerOf(c).check(manual: true);
      await controllerOf(c).update();
      final failed = c.read(githubUpdateProvider).status as UpdateFailed;
      expect(failed.message, contains('size'));
    });
  });

  test('a portable copy opens the release page', () async {
    await answerRelease();
    system.facts = const InstallFacts(
      os: 'windows',
      namesBesideExecutable: ['karmashala.exe'],
    );
    final c = await container();
    await controllerOf(c).start();
    await controllerOf(c).check(manual: true);
    await controllerOf(c).update();
    expect(openedUrls, [
      'https://github.com/lohanidamodar/karmashala/releases/tag/v1.35.0',
    ]);
    expect(http.downloads, isEmpty);
    expect(c.read(githubUpdateProvider).status, isA<UpdateHandedOff>());
  });

  test(
    'an AppImage is swapped in beside itself and restarts from it',
    () async {
      await answerRelease();
      const path = '/home/me/Apps/Karmashala.AppImage';
      system.facts = const InstallFacts(os: 'linux', appImage: path);
      final c = await container();
      await controllerOf(c).start();
      await controllerOf(c).check(manual: true);
      await controllerOf(c).update();
      expect(system.madeExecutable, ['$path.download']);
      expect(system.renamed, [('$path.download', path)]);
      final ready = c.read(githubUpdateProvider).status as UpdateReady;
      expect(ready.path, path);
      await controllerOf(c).install();
      expect(system.relaunched, [path]);
      expect(quits, 1);
    },
  );

  test('macOS opens the verified disk image', () async {
    await answerRelease();
    system.facts = const InstallFacts(os: 'macos');
    final c = await container();
    await controllerOf(c).start();
    await controllerOf(c).check(manual: true);
    await controllerOf(c).update();
    expect(system.opened, ['/tmp/karmashala-update/$_dmg']);
    expect(c.read(githubUpdateProvider).status, isA<UpdateHandedOff>());
    expect(quits, 0);
  });

  test('a sideloaded APK opens its download link', () async {
    await answerRelease();
    system.facts = const InstallFacts(
      os: 'android',
      androidInstallerKnown: true,
      androidInstaller: 'com.google.android.packageinstaller',
    );
    final c = await container();
    await controllerOf(c).start();
    await controllerOf(c).check(manual: true);
    await controllerOf(c).update();
    expect(openedUrls, [_url(_apk).toString()]);
    expect(http.downloads, isEmpty);
  });

  group('ReleaseFeed', () {
    test('a repository with no release is nothing to offer', () async {
      http.answers.add(const UpdateHttpResponse(404, '{}'));
      expect(await ReleaseFeed(http).latest(), isNull);
    });

    test('a socket failure reads as no connection', () async {
      http.throwOnGet = StateError('boom');
      expect(
        ReleaseFeed(http).latest(),
        throwsA(
          isA<ReleaseFeedException>().having(
            (e) => e.reason,
            'reason',
            contains('no connection'),
          ),
        ),
      );
    });

    test('asks for GitHub JSON and names itself', () async {
      http.answerJson(releaseJson());
      await ReleaseFeed(http, userAgent: 'Karmashala/1.0.0').latest();
      expect(http.checks.single['accept'], 'application/vnd.github+json');
      expect(http.checks.single['user-agent'], 'Karmashala/1.0.0');
    });
  });
}
