import 'dart:async';

import 'package:cryptography/dart.dart' show DartSha256;
import 'package:karmashala_core/logging.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/probe/probe_mode.dart';
import '../../git/application/remote_links.dart' show openExternalUrlProvider;
import '../../settings/application/settings_controller.dart';
import '../../system/system_integration_service.dart'
    show systemIntegrationProvider;
import '../data/io_update_http.dart';
import '../data/io_update_system.dart';
import '../domain/download_check.dart';
import '../domain/github_release.dart';
import '../domain/install_kind.dart';
import '../domain/release_version.dart';
import '../domain/update_status.dart';
import 'release_feed.dart';
import 'update_ports.dart';

final updateHttpProvider = Provider<UpdateHttp>((ref) => IoUpdateHttp());

final updateSystemProvider = Provider<UpdateSystem>((ref) => IoUpdateSystem());

final releaseFeedProvider = Provider<ReleaseFeed>(
  (ref) => ReleaseFeed(
    ref.watch(updateHttpProvider),
    userAgent: appVersion.isEmpty ? 'Karmashala' : 'Karmashala/$appVersion',
  ),
);

/// The running build's version; empty for an unstamped build, which never
/// checks on its own.
final runningVersionProvider = Provider<String>((ref) => appVersion);

/// When the app checks by itself.
final class UpdateSchedule {
  const UpdateSchedule({
    this.firstCheck = const Duration(seconds: 30),
    this.every = const Duration(hours: 6),
  });

  /// After launch: late enough to stay out of startup's way.
  final Duration firstCheck;
  final Duration every;
}

final updateScheduleProvider = Provider<UpdateSchedule>(
  (ref) => const UpdateSchedule(),
);

/// The app's real quit: closing the window may only hide it to the tray.
final updateQuitProvider = Provider<Future<void> Function()>(
  (ref) =>
      () async => ref.read(systemIntegrationProvider)?.quit(),
);

final githubUpdateProvider =
    NotifierProvider<GitHubUpdateController, GitHubUpdateState>(
      GitHubUpdateController.new,
    );

/// **Updates from GitHub releases**, for every install Google Play does not
/// update: checks the latest release, offers it, and carries the update out
/// the way this install kind needs (docs: PROJECT.md › In-app updates).
///
/// Automatic checks fail quietly into the log; the check from Settings says
/// what happened.
class GitHubUpdateController extends Notifier<GitHubUpdateState> {
  static final AppLogger _log = AppLogger.named('update');

  Timer? _first;
  Timer? _every;
  bool _started = false;
  bool _checking = false;
  bool _working = false;
  InstallFacts? _facts;

  @override
  GitHubUpdateState build() {
    ref.onDispose(() {
      _first?.cancel();
      _every?.cancel();
    });
    return const GitHubUpdateState();
  }

  /// Measures the install and starts the schedule. Once a launch; the
  /// app-wide notice calls it after the first frame.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final InstallFacts facts;
    try {
      facts = await ref.read(updateSystemProvider).installFacts();
    } on Object catch (error) {
      _log.info('Could not tell how Karmashala was installed: $error');
      state = state.copyWith(kind: InstallKind.unsupported);
      return;
    }
    _facts = facts;
    final kind = detectInstallKind(facts);
    state = state.copyWith(kind: kind);
    _log.info('Install kind: ${kind.name}.');
    if (!kind.usesGitHub) return;
    if (ReleaseVersion.tryParse(ref.read(runningVersionProvider)) == null) {
      return;
    }
    // A probe is a second copy built for testing: it never updates itself.
    if (ref.read(probeModeProvider).enabled) return;
    final schedule = ref.read(updateScheduleProvider);
    _first = Timer(schedule.firstCheck, () => unawaited(check()));
    _every = Timer.periodic(schedule.every, (_) => unawaited(check()));
  }

  /// Looks for a newer release. [manual] is the button in Settings: it runs
  /// whatever the switch says and reports failures; an automatic check only
  /// logs them.
  Future<void> check({bool manual = false}) async {
    final kind = state.kind;
    if (kind == null || !kind.usesGitHub || _checking) return;
    if (!manual && !ref.read(settingsControllerProvider).checkForUpdates) {
      return;
    }
    // An update under way is not interrupted by news of another.
    if (state.status case UpdateDownloading() || UpdateReady()) return;
    final current = ref.read(runningVersionProvider);
    if (ReleaseVersion.tryParse(current) == null) {
      if (manual) {
        state = state.copyWith(
          status: const UpdateFailed(
            'This build has no version recorded, so there is nothing to '
            'compare a release with.',
          ),
        );
      }
      return;
    }
    _checking = true;
    final before = state.status;
    if (manual) state = state.copyWith(status: const UpdateChecking());
    try {
      final release = await ref.read(releaseFeedProvider).latest();
      if (!ref.mounted) return;
      final plan = release == null || !release.offerable
          ? null
          : planUpdate(kind, release);
      if (release != null &&
          plan != null &&
          isNewerRelease(release.tag, current)) {
        _log.info('Release ${release.tag} is available (${plan.method.name}).');
        state = state.copyWith(status: UpdateAvailable(release, plan));
      } else {
        state = state.copyWith(status: UpdateUpToDate(DateTime.now()));
      }
    } on ReleaseFeedException catch (error) {
      _log.info('Update check did not answer: $error');
      if (!ref.mounted) return;
      state = state.copyWith(
        status: manual ? UpdateFailed('Could not check: $error.') : before,
      );
    } finally {
      _checking = false;
    }
  }

  /// Hides the notice until the next launch.
  void later() => state = state.copyWith(later: true);

  /// Hides this release's notice for good.
  void skip() {
    final release = state.release;
    if (release == null) return;
    ref
        .read(settingsControllerProvider.notifier)
        .setSkippedUpdateVersion(release.tag);
  }

  /// Update: opens a page or link, or downloads and verifies the file. An
  /// installer then waits for [install], which the person confirms.
  Future<void> update() async {
    final offer = switch (state.status) {
      final UpdateAvailable available => (available.release, available.plan),
      UpdateFailed(:final release?, :final plan?) => (release, plan),
      _ => null,
    };
    if (offer == null || _working) return;
    final (release, plan) = offer;
    _working = true;
    try {
      switch (plan.method) {
        case UpdateMethod.openReleasePage:
          await _openUrl(release.page.toString());
          state = state.copyWith(
            status: UpdateHandedOff(
              release,
              plan,
              'Opened the release page to download it from.',
            ),
          );
        case UpdateMethod.openApk:
          await _openUrl(plan.asset!.downloadUrl.toString());
          state = state.copyWith(
            status: UpdateHandedOff(
              release,
              plan,
              'Opened the download. Open the file when it finishes to install '
              'it.',
            ),
          );
        case UpdateMethod.runInstaller ||
            UpdateMethod.replaceAppImage ||
            UpdateMethod.openDiskImage:
          await _download(release, plan);
      }
    } on Object catch (error) {
      _log.info('Update to ${release.tag} failed: $error');
      if (ref.mounted) {
        state = state.copyWith(
          status: UpdateFailed(
            'The update did not finish: $error',
            release: release,
            plan: plan,
          ),
        );
      }
    } finally {
      _working = false;
    }
  }

  /// Runs the verified installer silently and quits, or restarts into the
  /// swapped AppImage. The caller has confirmed that the app will close.
  Future<void> install() async {
    final status = state.status;
    if (status is! UpdateReady || _working) return;
    _working = true;
    final system = ref.read(updateSystemProvider);
    try {
      switch (status.plan.method) {
        case UpdateMethod.runInstaller:
          _log.info(
            'Running the ${status.release.tag} installer and quitting.',
          );
          await system.startDetached(status.path, kInstallerArguments);
        case UpdateMethod.replaceAppImage:
          await system.relaunchAfterExit(status.path);
        default:
          return;
      }
      await ref.read(updateQuitProvider)();
    } on Object catch (error) {
      _log.info('Could not start the update: $error');
      if (ref.mounted) {
        state = state.copyWith(
          status: UpdateFailed(
            'Could not start the update: $error',
            release: status.release,
            plan: status.plan,
          ),
        );
      }
    } finally {
      _working = false;
    }
  }

  Future<void> _openUrl(String url) async {
    final opened = await ref.read(openExternalUrlProvider)(url);
    if (!opened) throw StateError('nothing could open $url');
  }

  Future<void> _download(GitHubRelease release, UpdatePlan plan) async {
    final asset = plan.asset!;
    final system = ref.read(updateSystemProvider);
    final appImage = _facts?.appImage;
    final replacing = plan.method == UpdateMethod.replaceAppImage;
    if (replacing && (appImage == null || appImage.isEmpty)) {
      throw StateError("the AppImage's own path is not known");
    }
    // Beside the AppImage, so the swap is a rename on one file system.
    final target = replacing
        ? '$appImage.download'
        : system.join(await system.downloadDirectory(), asset.name);
    state = state.copyWith(
      status: UpdateDownloading(release, plan, received: 0, total: asset.size),
    );
    final stream = await ref
        .read(updateHttpProvider)
        .download(asset.downloadUrl);
    if (stream.statusCode != 200) {
      throw StateError('GitHub answered HTTP ${stream.statusCode}');
    }
    final sink = await system.create(target);
    final hasher = const DartSha256().newHashSink();
    var received = 0;
    var shown = 0;
    // A redraw per percent, not per chunk.
    final step = asset.size > 100 ? asset.size ~/ 100 : 1;
    try {
      await for (final chunk in stream.bytes) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        if (received - shown >= step && ref.mounted) {
          shown = received;
          state = state.copyWith(
            status: UpdateDownloading(
              release,
              plan,
              received: received,
              total: asset.size,
            ),
          );
        }
      }
    } on Object {
      await sink.close();
      await _deleteQuietly(system, target);
      rethrow;
    }
    await sink.close();
    hasher.close();
    final hash = await hasher.hash();
    final hex = [
      for (final byte in hash.bytes) byte.toRadixString(16).padLeft(2, '0'),
    ].join();
    final verdict = checkDownload(asset, sha256Hex: hex, size: received);
    if (verdict != DownloadCheck.ok) {
      await _deleteQuietly(system, target);
      throw StateError('${verdict.problem}, so it was deleted');
    }
    if (!ref.mounted) return;
    switch (plan.method) {
      case UpdateMethod.runInstaller:
        state = state.copyWith(status: UpdateReady(release, plan, target));
      case UpdateMethod.replaceAppImage:
        await system.makeExecutable(target);
        await system.rename(target, appImage!);
        state = state.copyWith(status: UpdateReady(release, plan, appImage));
      case UpdateMethod.openDiskImage:
        await system.open(target);
        state = state.copyWith(
          status: UpdateHandedOff(
            release,
            plan,
            'Opened the disk image. Drag Karmashala into Applications, then '
            'quit and reopen it.',
          ),
        );
      default:
        break;
    }
  }

  Future<void> _deleteQuietly(UpdateSystem system, String path) async {
    try {
      await system.delete(path);
    } on Object catch (error) {
      _log.info('Could not delete $path: $error');
    }
  }
}
