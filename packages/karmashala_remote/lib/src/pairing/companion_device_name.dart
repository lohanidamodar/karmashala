/// What a phone calls itself in the row its desktop stores.
///
/// **A probe that failed must never answer `Companion` alone.** Two paired
/// phones reading the same word on the desktop is the bug this exists to fix,
/// so an unreadable model falls back to something still distinguishable.
String companionDeviceName({required String? model, required String deviceId}) {
  final named = model?.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (named != null && named.isNotEmpty) {
    // A row in a list, not a paragraph: a model string longer than this is a
    // vendor being expansive.
    return named.length <= maxCompanionDeviceName
        ? named
        : named.substring(0, maxCompanionDeviceName).trimRight();
  }
  final short = deviceId.trim();
  if (short.isEmpty) return 'Companion';
  return 'Companion · ${short.substring(0, short.length < 6 ? short.length : 6)}';
}

const int maxCompanionDeviceName = 40;
