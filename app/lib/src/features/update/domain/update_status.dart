import 'github_release.dart';
import 'install_kind.dart';

/// Where an update from GitHub stands.
sealed class UpdateStatus {
  const UpdateStatus();
}

/// Not checked yet this launch.
final class UpdateIdle extends UpdateStatus {
  const UpdateIdle();
}

final class UpdateChecking extends UpdateStatus {
  const UpdateChecking();
}

final class UpdateUpToDate extends UpdateStatus {
  const UpdateUpToDate(this.checkedAt);

  final DateTime checkedAt;
}

/// A newer release, and what Update would do with it.
sealed class UpdateOffered extends UpdateStatus {
  const UpdateOffered(this.release, this.plan);

  final GitHubRelease release;
  final UpdatePlan plan;
}

final class UpdateAvailable extends UpdateOffered {
  const UpdateAvailable(super.release, super.plan);
}

final class UpdateDownloading extends UpdateOffered {
  const UpdateDownloading(
    super.release,
    super.plan, {
    required this.received,
    required this.total,
  });

  final int received;

  /// Bytes expected; 0 when unknown.
  final int total;

  /// 0–1, or null when [total] is unknown.
  double? get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : null;
}

/// Downloaded and verified: an installer waiting to run, or an AppImage
/// swapped in and waiting for a restart.
final class UpdateReady extends UpdateOffered {
  const UpdateReady(super.release, super.plan, this.path);

  final String path;
}

/// Handed on to the system — a disk image opened, a download link or page
/// in the browser. Nothing further happens here.
final class UpdateHandedOff extends UpdateOffered {
  const UpdateHandedOff(super.release, super.plan, this.message);

  final String message;
}

/// A check or an update that failed, in words for the person.
final class UpdateFailed extends UpdateStatus {
  const UpdateFailed(this.message, {this.release, this.plan});

  final String message;

  /// Set when it failed while updating to it, so the notice can offer a
  /// retry; null for a failed check.
  final GitHubRelease? release;
  final UpdatePlan? plan;
}

/// Everything the notice and Settings › About draw.
final class GitHubUpdateState {
  const GitHubUpdateState({
    this.kind,
    this.status = const UpdateIdle(),
    this.later = false,
  });

  /// This install's kind, once measured; null before.
  final InstallKind? kind;
  final UpdateStatus status;

  /// Later was pressed: the notice stays away until the next launch.
  final bool later;

  GitHubUpdateState copyWith({
    InstallKind? kind,
    UpdateStatus? status,
    bool? later,
  }) => GitHubUpdateState(
    kind: kind ?? this.kind,
    status: status ?? this.status,
    later: later ?? this.later,
  );

  /// The release the notice is about, if any.
  GitHubRelease? get release => switch (status) {
    final UpdateOffered offered => offered.release,
    final UpdateFailed failed => failed.release,
    _ => null,
  };

  /// Whether the app-wide notice shows: something to offer, Later not pressed
  /// and the version not skipped. A failed check never shows.
  bool noticeVisible({required String skippedVersion}) {
    if (later) return false;
    final release = this.release;
    if (release == null) return false;
    // Once the person started an update it stays in view, skipped or not.
    if (status is UpdateAvailable && release.tag == skippedVersion) {
      return false;
    }
    return true;
  }
}
