/// What a verification run is *about*: a page in the browser, an app on a
/// device, or a change to the code itself.
///
/// Deliberately a closed set rather than a free-form string. Everything the
/// recorder does afterwards — which services it listens to, which artifacts it
/// collects at the end — is decided by this, so "some other kind of target"
/// must be a code change and not a typo. [change] is that code change: a
/// third kind was added deliberately, and adding it is exactly the review the
/// closed set exists to force.
enum VerificationTargetKind {
  browser('Browser'),
  device('Device'),

  /// The work itself — a diff, read and judged rather than driven.
  ///
  /// The kind a review session records against, and the only one that drives
  /// nothing: there is no page to attach to and no device to bring to the
  /// front, so the run's evidence is entirely what the reviewer writes with
  /// `verification_note` plus the verdict it finishes with.
  change('Change');

  const VerificationTargetKind(this.label);

  final String label;

  static VerificationTargetKind parse(String? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return VerificationTargetKind.browser;
  }
}

/// The address of the thing being verified.
class VerificationTarget {
  const VerificationTarget._({
    required this.kind,
    this.url,
    this.serial,
    this.packageName,
  });

  /// A page, by URL. The URL is the one the run *started* at; navigation during
  /// the run is recorded as steps.
  const VerificationTarget.browser(String url)
    : this._(kind: VerificationTargetKind.browser, url: url);

  /// A device, optionally narrowed to one app. [packageName] is what the logcat
  /// slice is filtered by, so a run without it collects nothing from the log.
  const VerificationTarget.device({required String serial, String? packageName})
    : this._(
        kind: VerificationTargetKind.device,
        serial: serial,
        packageName: packageName,
      );

  /// The change under review.
  ///
  /// Deliberately **addressless**. A page has a URL and a device has a serial;
  /// a change has neither, and the honest answer is to store nothing rather
  /// than reuse `target_url` for a branch name. What the run is about is
  /// already recorded twice over — `session_id` says whose work it is, and the
  /// run's title says which claim was checked.
  const VerificationTarget.change() : this._(kind: VerificationTargetKind.change);

  final VerificationTargetKind kind;
  final String? url;
  final String? serial;
  final String? packageName;

  bool get isBrowser => kind == VerificationTargetKind.browser;
  bool get isDevice => kind == VerificationTargetKind.device;

  /// Whether this run drives nothing and therefore installs no sinks.
  bool get isChange => kind == VerificationTargetKind.change;

  /// One line naming the target, for a list row or a report heading.
  String get label => switch (kind) {
    VerificationTargetKind.browser => url ?? '(no URL)',
    VerificationTargetKind.device =>
      packageName == null
          ? (serial ?? '(no serial)')
          : '${serial ?? '(no serial)'} · $packageName',
    VerificationTargetKind.change => 'the change under review',
  };

  @override
  String toString() => '${kind.label}: $label';
}
