/// Which Android emulator overhead this build is willing to switch off, and the
/// pure logic that turns a choice of categories into emulator flags, `adb shell
/// settings` writes and `pm disable-user` calls.
///
/// **Not a port of the iOS side.** There is no launchd on Android, so there is
/// no single file to write; the saving comes from three unrelated mechanisms
/// (see [AndroidSlimmingLayer]) with three different lifetimes. The iOS
/// `disabled.plist` is read at boot and nothing else, so it is start-only and
/// evaporates the moment this app stops writing it. Two of the three layers
/// here are `adb` calls against a booted device, and they **persist on the AVD
/// across reboots** — a user who switches slimming off keeps a device whose
/// animations are still zeroed and whose Play services are still disabled until
/// something puts them back. That is why every layer here has a restore path
/// ([settingsRestoreArguments], [enableArgumentsFor]) and why the UI says which
/// layer persists rather than implying the whole thing is per-run.
///
/// The polarity is inverted from iOS on purpose. iOS stores the categories to
/// *spare*, so a category added in a later release is slimmed by default. Here
/// the stored list is the categories to *apply*, so a category added later does
/// nothing until somebody ticks it: on iOS the unreviewed direction costs a
/// launchd service, here it would silently start disabling Play services on
/// everybody's emulators after an app update.
///
/// **Measured** on this machine (Windows 11 host; AVD `sambandha_test`, API 34
/// `google_apis` x86_64, 2 GB RAM, `hw.gpu.enabled=no`). One cold boot each —
/// `-no-snapshot-load`, `-no-window`, `-no-boot-anim` — timed from launch to
/// `sys.boot_completed`, then 45 s of settling before `dumpsys meminfo`:
///
/// | | stock | flags + animations | + all five package groups |
/// |---|---|---|---|
/// | boot | 26 s | 22 s | 21 s |
/// | processes | 373 | 354 | 312 |
/// | guest Used RAM | 1,462,865 K | 1,430,030 K | 1,125,061 K |
///
/// Read that honestly. **Layers 1 and 2 are not where the memory is**: 19
/// processes and 2% of used RAM, one run, well inside the noise of a single
/// boot. What they actually buy is a device that is nicer to drive — with the
/// animation scales at zero a screen settles as soon as it changes, which is
/// why the first `uiautomator dump` after a tap stops coming back "could not
/// get idle state". Layer 3 is the whole memory saving — 61 fewer processes and
/// 23% less used RAM — and it is also the layer that stops Firebase, Maps and
/// Play billing working, which is why it is off by default and warned about by
/// name.
///
/// Both durable layers were verified to survive a cold boot and then to be
/// fully undone by the restore path (`settings delete` back to unset,
/// `pm enable --user 0` back to enabled). The same run turned up the case the
/// allowlist exists for: that emulator already had `com.android.nfc` disabled
/// by something else, and restore correctly left it alone.
///
/// Everything in this file is pure. The service that runs the commands lives in
/// `data/android_slimming_service.dart`.
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
    note: 'Passed to the emulator when it starts. Nothing is written to the '
        'AVD — start it without these and it is back to stock.',
  ),

  /// `adb shell settings put`. **Written into the AVD's settings database**, so
  /// it survives reboots and outlives this app.
  settings(
    id: 'settings',
    displayName: 'Device settings',
    persists: true,
    note: 'Written into the emulator and kept across restarts. Use Restore to '
        'put them back — switching slimming off does not.',
  ),

  /// `pm disable-user --user 0`. Also written into the AVD, and the layer that
  /// genuinely breaks apps.
  packages(
    id: 'packages',
    displayName: 'Disabled packages',
    persists: true,
    note: 'Disabled on the emulator and kept across restarts. Apps that depend '
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

/// How the emulator renders the guest's screen.
///
/// A deliberate user-facing choice rather than a guessed default. This pane
/// streams the device, so the renderer is the difference between a live preview
/// and a black rectangle, and the right answer depends on the host's GPU and
/// its drivers. [auto] passes **no flag at all** — the emulator picks, and the
/// AVD's own `hw.gpu.mode` still applies, which is the only option that cannot
/// make an emulator that used to work stop working.
///
/// The modes are exactly the ones `emulator -help-gpu` lists on the installed
/// binary (36.6.11.0); `lavapipe` and `swangle` are omitted because they are
/// Vulkan/ANGLE variants of `swiftshader` with no reason to prefer them here.
enum AndroidGpuMode {
  auto(id: 'auto', displayName: 'Automatic', flag: null,
      description: 'Let the emulator choose. The AVD\'s own setting applies.'),
  host(id: 'host', displayName: 'Host GPU', flag: 'host',
      description: 'Usually the fastest, and the one that fails on a machine '
          'with no usable GPU driver — the preview goes black rather than '
          'slow.'),
  swiftshader(id: 'swiftshader', displayName: 'SwiftShader (software)',
      flag: 'swiftshader',
      description: 'Renders on the CPU. Slower, and works anywhere — the '
          'fallback when Host GPU shows nothing.'),
  software(id: 'software', displayName: 'Legacy software', flag: 'software',
      description: 'The old software renderer. Slowest; only worth trying if '
          'SwiftShader also fails.');

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

/// A group of emulator overhead that is switched on and off together.
///
/// Grouping is what makes this safe to put in front of a person: "I still want
/// Play services" is a decision somebody can make, and `com.google.android.gsf`
/// is not.
///
/// The [id] is deliberately a field rather than [name]: it is what a saved
/// preference stores, so renaming a constant must not silently change which
/// categories are applied on everybody's machines.
enum AndroidSlimmingCategory {
  // ---- Layer 1: emulator flags. Cheap, per-start, nothing written. ---------
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

  // ---- Layer 2: device settings. Persists on the AVD. ---------------------
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

  // ---- Layer 3: packages. Persists, and this is where apps break. ---------
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
  /// causes it.
  ///
  /// Only entries confirmed by hand are listed. An empty map means "nothing a
  /// developer was likely to be using", not "verified harmless".
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

/// The categories applied by default, as ids.
///
/// Everything in layers 1 and 2, nothing in layer 3. The split is not about
/// size — layer 3 is where all the memory is — it is about what a user can
/// diagnose. A flag that is not passed and an animation scale that is zero
/// cannot make an app misbehave in a way that looks like a bug in the app;
/// `com.google.android.gms` being disabled absolutely can, and it looks exactly
/// like Firebase being broken.
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

/// Every package this build will ever disable, in either direction.
///
/// **This set is the safety mechanism.** Slimming is an allowlist, never a
/// denylist: nothing outside it is ever passed to `pm`, so a typo or a stale
/// saved category id cannot reach a package the system cannot live without.
///
/// Absent from the table below, on purpose and asserted by a test: `android`,
/// `com.android.systemui`, `com.android.settings`, `com.android.shell`, the
/// `com.android.providers.*` content providers, the WebView providers
/// (`com.google.android.webview`, `com.android.chrome`), the launcher
/// (`com.google.android.apps.nexuslauncher`), the keyboard
/// (`com.google.android.inputmethod.latin` — this pane types through it), the
/// permission controller and package installer, TalkBack, and the Contacts and
/// Dialer apps that own the system contact picker.
Set<String> get allManagedPackages => _allManagedPackages;

final Set<String> _allManagedPackages = Set.unmodifiable({
  for (final category in AndroidSlimmingCategory.values) ...category.packages,
});

/// The selected categories, from stored ids.
///
/// Ids that no longer name a category are dropped rather than erroring: a
/// category removed in a later release must not make a saved preference
/// unreadable.
Set<AndroidSlimmingCategory> categoriesFromIds(Iterable<String> ids) => {
  for (final id in ids) ?AndroidSlimmingCategory.byId(id),
};

/// Extra `emulator` arguments for [enabled], plus the [gpu] mode.
///
/// Order is stable so a test can assert the whole argv, and categories are
/// walked in declaration order rather than set order for the same reason.
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
///
/// One command per key rather than one chained shell line: `settings put` is
/// cheap, and a single failure then costs one setting instead of all three.
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
///
/// `settings delete`, not `put 1.0`. Stock Android leaves these keys unset and
/// the framework treats absent as 1.0, so deleting restores the state the
/// device actually shipped with, where writing 1.0 would leave our fingerprint
/// behind — the same reason the iOS side removes its plist keys rather than
/// writing an explicit `false`.
///
/// Takes no selection: restore always covers everything this build manages, so
/// a user who unticks a category and then restores is not left with the one
/// setting nobody put back.
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
///
/// `disable-user`, not `disable`: `pm disable` needs a privileged caller and is
/// refused for a system package from the adb shell, while `disable-user --user
/// 0` is the reversible per-user form that actually works on a stock image.
/// `--user 0` because an emulator has exactly one user and naming it keeps the
/// command from depending on which user `pm` picks.
///
/// Returns empty for a package outside [allManagedPackages] — the allowlist,
/// enforced at the point of use rather than trusted at the caller.
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

/// The feature-loss notes that apply to a given choice, keyed by the flag,
/// setting or package that causes each. Intended to be shown before the button
/// is pressed.
Map<String, String> featureLossFor({
  Set<AndroidSlimmingCategory> enabled = const {},
}) => {
  for (final category in AndroidSlimmingCategory.values)
    if (enabled.contains(category)) ...category.featureLoss,
};

// ---------------------------------------------------------------------------
// The package table. Every entry was confirmed present in `pm list packages` on
// a stock API 34 `google_apis` x86_64 emulator image. A package that is not on
// the image makes `pm disable-user` fail, which the service logs and swallows,
// so a stale entry costs one failed command and nothing else.
// ---------------------------------------------------------------------------

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
