/// What a verification run is *about*: a page, a device, or a change to the
/// code. A closed set, because everything the recorder does turns on it.
enum VerificationTargetKind {
  browser('Browser'),
  device('Device'),

  /// The work itself — driving nothing, so its evidence is what a reviewer
  /// writes.
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

  /// A page, by the URL the run *started* at; navigation is recorded as steps.
  const VerificationTarget.browser(String url)
    : this._(kind: VerificationTargetKind.browser, url: url);

  /// A device, optionally narrowed to one app: without [packageName] the
  /// logcat slice collects nothing.
  const VerificationTarget.device({required String serial, String? packageName})
    : this._(
        kind: VerificationTargetKind.device,
        serial: serial,
        packageName: packageName,
      );

  /// The change under review. Addressless: `session_id` and the title say it.
  const VerificationTarget.change()
    : this._(kind: VerificationTargetKind.change);

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
