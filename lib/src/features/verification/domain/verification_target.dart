/// What a verification run is *about*: a page in the browser, or an app on a
/// device.
///
/// Deliberately a closed pair rather than a free-form string. Everything the
/// recorder does afterwards — which services it listens to, which artifacts it
/// collects at the end — is decided by this, so "some other kind of target"
/// must be a code change and not a typo.
enum VerificationTargetKind {
  browser('Browser'),
  device('Device');

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

  final VerificationTargetKind kind;
  final String? url;
  final String? serial;
  final String? packageName;

  bool get isBrowser => kind == VerificationTargetKind.browser;
  bool get isDevice => kind == VerificationTargetKind.device;

  /// One line naming the target, for a list row or a report heading.
  String get label => switch (kind) {
    VerificationTargetKind.browser => url ?? '(no URL)',
    VerificationTargetKind.device =>
      packageName == null
          ? (serial ?? '(no serial)')
          : '${serial ?? '(no serial)'} · $packageName',
  };

  @override
  String toString() => '${kind.label}: $label';
}
