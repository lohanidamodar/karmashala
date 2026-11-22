import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/update/domain/download_check.dart';
import 'package:karmashala/src/features/update/domain/github_release.dart';
import 'package:karmashala/src/features/update/domain/install_kind.dart';
import 'package:karmashala/src/features/update/domain/release_version.dart';
import 'package:karmashala/src/features/update/domain/update_status.dart';

import 'update_fakes.dart';

void main() {
  group('ReleaseVersion', () {
    ReleaseVersion v(String raw) => ReleaseVersion.tryParse(raw)!;

    test('reads a tag, a bare version and a Play build stamp alike', () {
      expect(v('v1.34.27'), const ReleaseVersion(1, 34, 27));
      expect(v('1.34.27'), const ReleaseVersion(1, 34, 27));
      expect(v('1.34.27+94'), const ReleaseVersion(1, 34, 27));
      expect(v('v2'), const ReleaseVersion(2, 0, 0));
    });

    test('refuses what is not a version', () {
      for (final raw in ['', 'latest', 'v1.x', '1.2.3.4', 'release-1']) {
        expect(ReleaseVersion.tryParse(raw), isNull, reason: raw);
      }
    });

    test('orders by number, not by text', () {
      expect(v('1.34.10') > v('1.34.9'), isTrue);
      expect(v('1.10.0') > v('1.9.99'), isTrue);
      expect(v('2.0.0') > v('1.99.99'), isTrue);
    });

    test('ranks a prerelease below its release, as semver does', () {
      expect(v('1.35.0') > v('1.35.0-rc.1'), isTrue);
      expect(v('1.35.0-rc.2') > v('1.35.0-rc.1'), isTrue);
      expect(v('1.35.0-rc.10') > v('1.35.0-rc.9'), isTrue);
      expect(v('1.35.0-beta') > v('1.35.0-alpha'), isTrue);
      expect(v('1.35.0-alpha.1') > v('1.35.0-alpha'), isTrue);
    });

    test('isNewerRelease never offers to an unstamped build', () {
      expect(isNewerRelease('v1.35.0', '1.34.27'), isTrue);
      expect(isNewerRelease('v1.34.27', '1.34.27+94'), isFalse);
      expect(isNewerRelease('v1.34.26', '1.34.27'), isFalse);
      expect(isNewerRelease('v1.35.0', ''), isFalse);
      expect(isNewerRelease('nightly', '1.0.0'), isFalse);
    });
  });

  group('GitHubRelease.fromJson', () {
    test('keeps the tag, page, notes and well-formed assets', () {
      final release = GitHubRelease.fromJson(
        releaseJson(
          assets: [
            assetJson('Karmashala-Setup-1.35.0.exe', 10, digest: 'sha256:ab'),
            {'name': 'broken'},
            {
              'name': 'plain-http.zip',
              'size': 1,
              'browser_download_url': 'http://example.com/x',
            },
          ],
        ),
      )!;
      expect(release.tag, 'v1.35.0');
      expect(release.versionText, '1.35.0');
      expect(release.notes, contains('Fixed'));
      expect(release.offerable, isTrue);
      expect(release.assets.map((a) => a.name), [
        'Karmashala-Setup-1.35.0.exe',
      ]);
      expect(release.assets.single.digest, 'sha256:ab');
    });

    test('a draft or a prerelease is never offerable', () {
      expect(
        GitHubRelease.fromJson(releaseJson(draft: true))!.offerable,
        isFalse,
      );
      expect(
        GitHubRelease.fromJson(releaseJson(prerelease: true))!.offerable,
        isFalse,
      );
      expect(
        GitHubRelease.fromJson(releaseJson(tag: 'v1.35.0-rc.1'))!.offerable,
        isFalse,
      );
    });

    test('a tag that is not a version is not a release', () {
      expect(GitHubRelease.fromJson(releaseJson(tag: 'vnext')), isNull);
      expect(GitHubRelease.fromJson('nope'), isNull);
    });
  });

  group('detectInstallKind', () {
    test('Windows: an Inno uninstaller beside the exe means the installer', () {
      expect(
        detectInstallKind(
          const InstallFacts(
            os: 'windows',
            namesBesideExecutable: ['karmashala.exe', 'unins000.exe'],
          ),
        ),
        InstallKind.windowsInstaller,
      );
      expect(
        detectInstallKind(
          const InstallFacts(
            os: 'windows',
            namesBesideExecutable: ['karmashala.exe', 'flutter_windows.dll'],
          ),
        ),
        InstallKind.windowsPortable,
      );
    });

    test('Linux: APPIMAGE set means an AppImage', () {
      expect(
        detectInstallKind(
          const InstallFacts(os: 'linux', appImage: '/home/me/K.AppImage'),
        ),
        InstallKind.linuxAppImage,
      );
      expect(
        detectInstallKind(const InstallFacts(os: 'linux', appImage: '')),
        InstallKind.linuxTarball,
      );
    });

    test('Android: Play keeps Play, and an unanswered question does too', () {
      expect(
        detectInstallKind(
          const InstallFacts(
            os: 'android',
            androidInstallerKnown: true,
            androidInstaller: kPlayStoreInstaller,
          ),
        ),
        InstallKind.androidPlay,
      );
      expect(
        detectInstallKind(const InstallFacts(os: 'android')),
        InstallKind.androidPlay,
      );
      expect(
        detectInstallKind(
          const InstallFacts(
            os: 'android',
            androidInstallerKnown: true,
            androidInstaller: 'com.google.android.packageinstaller',
          ),
        ),
        InstallKind.androidSideloaded,
      );
      expect(
        detectInstallKind(
          const InstallFacts(os: 'android', androidInstallerKnown: true),
        ),
        InstallKind.androidSideloaded,
      );
    });

    test('macOS, iOS and the web', () {
      expect(
        detectInstallKind(const InstallFacts(os: 'macos')),
        InstallKind.macos,
      );
      expect(
        detectInstallKind(const InstallFacts(os: 'ios')),
        InstallKind.unsupported,
      );
      expect(
        detectInstallKind(const InstallFacts(os: 'web')),
        InstallKind.unsupported,
      );
    });
  });

  group('planUpdate', () {
    final release = GitHubRelease.fromJson(
      releaseJson(
        assets: [
          for (final name in [
            'Karmashala-Setup-1.35.0.exe',
            'Karmashala-windows-portable.zip',
            'Karmashala-1.35.0-x86_64.AppImage',
            'Karmashala-linux.tar.gz',
            'Karmashala-macOS-1.35.0.dmg',
            'Karmashala-android-1.35.0.apk',
          ])
            assetJson(name, 1),
        ],
      ),
    )!;

    test('each install kind takes its own file, or the page', () {
      final expected = {
        InstallKind.windowsInstaller: (
          UpdateMethod.runInstaller,
          'Karmashala-Setup-1.35.0.exe',
        ),
        InstallKind.windowsPortable: (UpdateMethod.openReleasePage, null),
        InstallKind.linuxAppImage: (
          UpdateMethod.replaceAppImage,
          'Karmashala-1.35.0-x86_64.AppImage',
        ),
        InstallKind.linuxTarball: (UpdateMethod.openReleasePage, null),
        InstallKind.macos: (
          UpdateMethod.openDiskImage,
          'Karmashala-macOS-1.35.0.dmg',
        ),
        InstallKind.androidSideloaded: (
          UpdateMethod.openApk,
          'Karmashala-android-1.35.0.apk',
        ),
      };
      expected.forEach((kind, want) {
        final plan = planUpdate(kind, release)!;
        expect(plan.method, want.$1, reason: kind.name);
        expect(plan.asset?.name, want.$2, reason: kind.name);
      });
    });

    test('Play and unsupported installs get no plan', () {
      expect(planUpdate(InstallKind.androidPlay, release), isNull);
      expect(planUpdate(InstallKind.unsupported, release), isNull);
    });

    test('a release missing the file falls back to its page', () {
      final bare = GitHubRelease.fromJson(releaseJson())!;
      expect(
        planUpdate(InstallKind.windowsInstaller, bare)!.method,
        UpdateMethod.openReleasePage,
      );
    });
  });

  group('checkDownload', () {
    const hex =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    ReleaseAsset asset({String? digest, int size = 0}) => ReleaseAsset(
      name: 'x',
      size: size,
      downloadUrl: Uri.parse('https://example.com/x'),
      digest: digest,
    );

    test('a digest is compared when GitHub has one', () {
      expect(
        checkDownload(asset(digest: 'sha256:$hex'), sha256Hex: hex, size: 0),
        DownloadCheck.ok,
      );
      expect(
        checkDownload(
          asset(digest: 'sha256:${hex.toUpperCase()}'),
          sha256Hex: hex,
          size: 0,
        ),
        DownloadCheck.ok,
      );
      expect(
        checkDownload(asset(digest: 'sha256:00'), sha256Hex: hex, size: 0),
        DownloadCheck.digestMismatch,
      );
    });

    test('without one, the size alone decides', () {
      expect(
        checkDownload(asset(size: 5), sha256Hex: hex, size: 5),
        DownloadCheck.ok,
      );
      expect(
        checkDownload(asset(size: 5), sha256Hex: hex, size: 4),
        DownloadCheck.sizeMismatch,
      );
      // A digest in another algorithm is not one this can check.
      expect(
        checkDownload(
          asset(digest: 'sha512:ff', size: 5),
          sha256Hex: hex,
          size: 5,
        ),
        DownloadCheck.ok,
      );
    });
  });

  group('noticeVisible', () {
    final release = GitHubRelease.fromJson(releaseJson())!;
    const plan = UpdatePlan(UpdateMethod.openReleasePage);

    test('shows an offer until Later or Skip', () {
      final offered = GitHubUpdateState(
        kind: InstallKind.windowsPortable,
        status: UpdateAvailable(release, plan),
      );
      expect(offered.noticeVisible(skippedVersion: ''), isTrue);
      expect(offered.noticeVisible(skippedVersion: 'v1.35.0'), isFalse);
      expect(
        offered.copyWith(later: true).noticeVisible(skippedVersion: ''),
        isFalse,
      );
    });

    test('a failed check never shows; a failed update does', () {
      expect(
        const GitHubUpdateState(
          status: UpdateFailed('Could not check'),
        ).noticeVisible(skippedVersion: ''),
        isFalse,
      );
      expect(
        GitHubUpdateState(
          status: UpdateFailed('bad', release: release, plan: plan),
        ).noticeVisible(skippedVersion: ''),
        isTrue,
      );
    });
  });
}
