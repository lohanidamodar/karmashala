/// Which Android emulator overhead this build is willing to switch off, and the
/// pure logic that turns a choice of categories into emulator flags, `settings`
/// writes and `pm disable-user` calls. Two of the three layers **persist on the
/// AVD across reboots**, which is why every layer has a restore path.
library;

/// The mechanism a category uses, and — the point of the type — how long its
/// effect lasts.
enum AndroidSlimmingLayer {
  /// Extra `emulator` argv. Per start: not passing them next time is the whole
  /// of the undo.
  launch(
    id: 'launch',
    displayName: 'Launch flags',
    persists: false,
    note:
        'Passed to the emulator when it starts. Nothing is written to the '
        'AVD — start it without these and it is back to stock.',
  ),

  /// `adb shell settings put`. **Written into the AVD's settings database**, so
  /// it survives reboots and outlives this app.
  settings(
    id: 'settings',
    displayName: 'Device settings',
    persists: true,
    note:
        'Written into the emulator and kept across restarts. Use Restore to '
        'put them back — switching slimming off does not.',
  ),

  /// `pm disable-user --user 0`. Also written into the AVD, and the layer that
  /// genuinely breaks apps.
  packages(
    id: 'packages',
    displayName: 'Disabled packages',
    persists: true,
    note:
        'Disabled on the emulator and kept across restarts. Apps that depend '
        'on them stop working until Restore re-enables them.',
  );

  const AndroidSlimmingLayer({
    required this.id,
    required this.displayName,
    required this.persists,
    required this.note,
  });

  final String id;
  final String displayName;

  /// Whether the change outlives the emulator process.
  final bool persists;

  /// One sentence for the UI, above the categories in this layer.
  final String note;
}

/// How the emulator renders the guest's screen. A user-facing choice, because
/// the right answer depends on the host's GPU: [auto] passes **no flag at all**,
/// the only option that cannot make a working emulator stop working.
enum AndroidGpuMode {
  auto(
    id: 'auto',
    displayName: 'Automatic',
    flag: null,
    description: 'Let the emulator choose. The AVD\'s own setting applies.',
  ),
  host(
    id: 'host',
    displayName: 'Host GPU',
    flag: 'host',
    description:
        'Usually the fastest, and the one that fails on a machine '
        'with no usable GPU driver — the preview goes black rather than '
        'slow.',
  ),
  swiftshader(
    id: 'swiftshader',
    displayName: 'SwiftShader (software)',
    flag: 'swiftshader',
    description:
        'Renders on the CPU. Slower, and works anywhere — the '
        'fallback when Host GPU shows nothing.',
  ),
  software(
    id: 'software',
    displayName: 'Legacy software',
    flag: 'software',
    description:
        'The old software renderer. Slowest; only worth trying if '
        'SwiftShader also fails.',
  );

  const AndroidGpuMode({
    required this.id,
    required this.displayName,
    required this.flag,
    required this.description,
  });

  /// Stable identifier for persistence, never [name] — see
  /// [AndroidSlimmingCategory.id].
  final String id;
  final String displayName;

  /// The value for `-gpu`, or null to pass nothing.
  final String? flag;

  final String description;

  /// `['-gpu', flag]`, or empty for [auto].
  List<String> get arguments => flag == null ? const [] : ['-gpu', flag!];

  static AndroidGpuMode byId(String id) {
    for (final mode in values) {
      if (mode.id == id) return mode;
    }
    return AndroidGpuMode.auto;
  }
}

/// A group of emulator overhead switched on and off together. [id] is a field
/// rather than [name]: it is what a saved preference stores.
enum AndroidSlimmingCategory {
  /// Every flag below was confirmed against the installed binary with
  /// `emulator -help-<flag>` before it shipped.
  audio(
    id: 'audio',
    layer: AndroidSlimmingLayer.launch,
    displayName: 'Emulated audio device',
    description:
        'Starts the emulator with -no-audio. The live view here never carries '
        'audio (the stream is started with audio=false), so this costs nothing '
        'to watch.',
    flags: ['-no-audio'],
    featureLoss: {
      '-no-audio':
          'The guest has no audio device at all, so playback and recording in '
          'the app under test go nowhere.',
    },
  ),

  metrics(
    id: 'metrics',
    layer: AndroidSlimmingLayer.launch,
    displayName: 'Emulator usage metrics',
    description:
        'Starts with -no-metrics. Also skips the metrics consent prompt, which '
        'is what otherwise blocks a first start until somebody answers it.',
    flags: ['-no-metrics'],
  ),

  passiveGps(
    id: 'gps',
    layer: AndroidSlimmingLayer.launch,
    displayName: 'Passive location updates',
    description:
        'Starts with -no-passive-gps, so the emulator stops pushing a default '
        'location into the guest every few seconds.',
    flags: ['-no-passive-gps'],
    featureLoss: {
      '-no-passive-gps':
          'A device with no location set reports none at all. A location sent '
          'to the emulator console by hand still applies.',
    },
  ),

  // Layer 2: device settings, which persist on the AVD.
  animations(
    id: 'animations',
    layer: AndroidSlimmingLayer.settings,
    displayName: 'Window animations',
    description:
        'Sets the three animation scales to 0 — the classic win for anything '
        'driving the UI, which is what this pane is for: a screen with no '
        'transition to wait out settles sooner, so taps land and the '
        'accessibility tree reads correctly on the first try.',
    settingsKeys: _animationScaleKeys,
    featureLoss: {
      'window_animation_scale':
          'Transitions happen instantly. That is the point, but it also means '
          'a screen recording shows no animation, so this is the wrong thing '
          'to leave on while filming a demo.',
    },
  ),

  // Layer 3: packages. Persists, and this is where apps break.
  playServices(
    id: 'gms',
    layer: AndroidSlimmingLayer.packages,
    displayName: 'Google Play services',
    description:
        'Play services, the Services Framework and the Play Store. The largest '
        'single saving on the device, and the one that breaks the most.',
    packages: _playServices,
    featureLoss: {
      'com.google.android.gms':
          'Everything built on Play services stops: Firebase (including FCM '
          'push), Google sign-in, the Maps SDK, fused location, Play Integrity, '
          'ML Kit. If your app links play-services at all, leave this on.',
      'com.android.vending':
          'The Play Store and Play Billing are gone, so in-app purchase '
          'testing cannot work.',
    },
  ),

  assistant(
    id: 'assistant',
    layer: AndroidSlimmingLayer.packages,
    displayName: 'Google app, Assistant & system intelligence',
    description:
        'The Google app (the largest single process on a stock emulator here, '
        '154 MB), Assistant, Android System Intelligence and the text-to-speech '
        'engine.',
    packages: _assistant,
    featureLoss: {
      'com.google.android.tts':
          'The only TextToSpeech engine on the image goes away, so TTS falls '
          'silent rather than erroring.',
      'com.google.android.as':
          'Smart replies, live caption and the suggestion engines behind the '
          'keyboard stop. The keyboard itself is untouched.',
    },
  ),

  media(
    id: 'media',
    layer: AndroidSlimmingLayer.packages,
    displayName: 'YouTube, Music & Photos',
    description:
        'The three preinstalled media apps. None of them is a system service; '
        'they are here because they run anyway.',
    packages: _media,
    featureLoss: {
      'com.google.android.apps.photos':
          'Google Photos disappears from share and pick chooser sheets. The '
          'system photo picker is a different package and still works.',
    },
  ),

  bundledApps(
    id: 'apps',
    layer: AndroidSlimmingLayer.packages,
    displayName: 'Bundled Google apps',
    description:
        'Maps, Gmail, Calendar, Drive, Messages, Clock, Wellbeing, Android '
        'Auto and the wallpaper pickers.',
    packages: _bundledApps,
    featureLoss: {
      'com.google.android.apps.maps':
          'A map intent has nothing to open. An embedded MapView is part of '
          'Play services, not this app, so it is unaffected.',
    },
  ),

  feedback(
    id: 'feedback',
    layer: AndroidSlimmingLayer.packages,
    displayName: 'Feedback, ads & federated learning',
    description:
        'Crash feedback, the ad-services and on-device personalisation '
        'modules, and federated compute. Pure overhead on a machine nobody is '
        'measuring.',
    packages: _feedback,
  );

  const AndroidSlimmingCategory({
    required this.id,
    required this.layer,
    required this.displayName,
    required this.description,
    this.flags = const [],
    this.settingsKeys = const [],
    this.packages = const [],
    this.featureLoss = const {},
  });

  /// Stable identifier for persistence. Never derived from [name], so the enum
  /// constant can be renamed without changing what a saved selection means.
  final String id;

  final AndroidSlimmingLayer layer;

  /// What to call this in a UI.
  final String displayName;

  /// One paragraph a developer can decide from.
  final String description;

  /// Extra `emulator` argv, for [AndroidSlimmingLayer.launch].
  final List<String> flags;

  /// `settings put global` keys set to 0, for [AndroidSlimmingLayer.settings].
  final List<String> settingsKeys;

  /// Packages to `pm disable-user`, for [AndroidSlimmingLayer.packages].
  final List<String> packages;

  /// What visibly stops working, keyed by the flag, setting or package that
  /// causes it. An empty map means "nothing likely", not "verified harmless".
  final Map<String, String> featureLoss;

  /// The category whose [id] is [id], or null.
  static AndroidSlimmingCategory? byId(String id) {
    for (final category in values) {
      if (category.id == id) return category;
    }
    return null;
  }

  static List<AndroidSlimmingCategory> inLayer(AndroidSlimmingLayer layer) => [
    for (final category in values)
      if (category.layer == layer) category,
  ];
}

/// The categories applied by default, as ids: everything in layers 1 and 2. The
/// split is about what a user can diagnose, not about size.
const List<String> kDefaultAndroidSlimming = [
  'audio',
  'metrics',
  'gps',
  'animations',
];

/// The three scales Android exposes. All default to 1.0 when unset.
const List<String> _animationScaleKeys = [
  'window_animation_scale',
  'transition_animation_scale',
  'animator_duration_scale',
];

/// Every `settings` key this build will ever write, in either direction.
Set<String> get allManagedSettingsKeys => _allManagedSettingsKeys;

final Set<String> _allManagedSettingsKeys = Set.unmodifiable({
  for (final category in AndroidSlimmingCategory.values)
    ...category.settingsKeys,
});

/// Every package this build will ever disable, in either direction. **This set
/// is the safety mechanism:** slimming is an allowlist, never a denylist, so a
/// typo or a stale saved id cannot reach a package the system needs.
Set<String> get allManagedPackages => _allManagedPackages;

final Set<String> _allManagedPackages = Set.unmodifiable({
  for (final category in AndroidSlimmingCategory.values) ...category.packages,
});

/// The selected categories, from stored ids. Unknown ids are dropped: a category
/// removed in a later release must not make a saved preference unreadable.
Set<AndroidSlimmingCategory> categoriesFromIds(Iterable<String> ids) => {
  for (final id in ids) ?AndroidSlimmingCategory.byId(id),
};

/// Extra `emulator` arguments for [enabled], plus the [gpu] mode. Order is
/// stable so a test can assert the whole argv.
List<String> launchArguments({
  Set<AndroidSlimmingCategory> enabled = const {},
  AndroidGpuMode gpu = AndroidGpuMode.auto,
}) => [
  for (final category in AndroidSlimmingCategory.values)
    if (category.layer == AndroidSlimmingLayer.launch &&
        enabled.contains(category))
      ...category.flags,
  ...gpu.arguments,
];

/// `adb shell` argument lists that apply the layer-2 settings for [enabled].
/// One command per key, so one failure costs one setting instead of three.
List<List<String>> settingsArguments({
  Set<AndroidSlimmingCategory> enabled = const {},
}) => [
  for (final category in AndroidSlimmingCategory.values)
    if (category.layer == AndroidSlimmingLayer.settings &&
        enabled.contains(category))
      for (final key in category.settingsKeys)
        ['shell', 'settings', 'put', 'global', key, '0'],
];

/// `adb shell` argument lists that put **every** managed setting back.
/// `settings delete`, not `put 1.0`: absent is the state the device shipped in.
List<List<String>> settingsRestoreArguments() => [
  for (final key in _orderedManagedSettingsKeys)
    ['shell', 'settings', 'delete', 'global', key],
];

final List<String> _orderedManagedSettingsKeys = List.unmodifiable([
  for (final category in AndroidSlimmingCategory.values)
    ...category.settingsKeys,
]);

/// Packages to disable for [enabled].
Set<String> packagesFor({Set<AndroidSlimmingCategory> enabled = const {}}) => {
  for (final category in AndroidSlimmingCategory.values)
    if (category.layer == AndroidSlimmingLayer.packages &&
        enabled.contains(category))
      ...category.packages,
};

/// `adb shell` arguments that disable [package] for the primary user.
/// `disable-user`, not `disable`, which the adb shell is not privileged for.
/// Empty outside [allManagedPackages] — the allowlist, enforced at the use.
List<String> disableArgumentsFor(String package) =>
    allManagedPackages.contains(package)
    ? ['shell', 'pm', 'disable-user', '--user', '0', package]
    : const [];

/// `adb shell` arguments that put [package] back. The exact inverse of
/// [disableArgumentsFor].
List<String> enableArgumentsFor(String package) =>
    allManagedPackages.contains(package)
    ? ['shell', 'pm', 'enable', '--user', '0', package]
    : const [];

/// The feature-loss notes that apply to a given choice, keyed by cause.
/// Meant to be shown before the button is pressed.
Map<String, String> featureLossFor({
  Set<AndroidSlimmingCategory> enabled = const {},
}) => {
  for (final category in AndroidSlimmingCategory.values)
    if (enabled.contains(category)) ...category.featureLoss,
};

// Every entry below was confirmed present in `pm list packages` on a stock API
// 34 image; a stale one costs one failed command, which the service swallows.

const List<String> _playServices = [
  'com.google.android.gms',
  'com.google.android.gsf',
  'com.android.vending',
  'com.google.android.gms.supervision',
  'com.google.android.onetimeinitializer',
  'com.google.android.partnersetup',
  'com.google.android.configupdater',
];

const List<String> _assistant = [
  'com.google.android.googlequicksearchbox',
  'com.google.android.as',
  'com.google.android.as.oss',
  'com.google.android.tts',
  'com.google.android.settings.intelligence',
];

const List<String> _media = [
  'com.google.android.youtube',
  'com.google.android.apps.youtube.music',
  'com.google.android.apps.photos',
];

const List<String> _bundledApps = [
  'com.google.android.apps.maps',
  'com.google.android.gm',
  'com.google.android.calendar',
  'com.google.android.apps.docs',
  'com.google.android.apps.messaging',
  'com.google.android.deskclock',
  'com.google.android.apps.wellbeing',
  'com.google.android.apps.restore',
  'com.google.android.projection.gearhead',
  'com.google.android.markup',
  'com.google.android.apps.wallpaper',
  'com.google.android.apps.wallpaper.nexus',
  'com.google.android.apps.customization.pixel',
];

const List<String> _feedback = [
  'com.google.android.feedback',
  'com.google.android.printservice.recommendation',
  'com.google.android.federatedcompute',
  'com.google.android.ondevicepersonalization.services',
  'com.google.android.adservices.api',
  'com.google.android.odad',
];
