/// Which iOS Simulator background services this build is willing to switch off,
/// and the pure logic that turns a choice of categories into a set of launchd
/// labels to disable.
///
/// A stock iOS 26 simulator boots ~358 launchd services. Most of them exist to
/// serve a *user* — widgets, Siri, iCloud sync, Health, the App Store — and
/// nothing a developer does with a simulator needs them. Measured on an
/// iPhone 17 / iOS 26.5 device here: 358 services down to 192, 149 running down
/// to 52, summed `phys_footprint` **3.09 GB down to 0.91 GB**, boot 15.8s down
/// to 9.6s, with SpringBoard still compositing and app launch and screenshot
/// still working.
///
/// Everything here is pure. The file that makes it real, and the rules about
/// when it may be written, live in `data/simulator_slimming_service.dart`.
library;

/// A group of launchd services that are switched on and off together.
///
/// Grouping is what makes this safe to put in front of a person: "I still want
/// push notifications" is a decision somebody can make, and
/// "com.apple.apsd" is not.
///
/// The [id] is deliberately a field rather than [name]: it is what a saved
/// preference or a CLI flag stores, so renaming a constant must not silently
/// re-enable a category on everybody's machines.
enum SlimmingCategory {
  /// The single biggest win, and the one nobody misses: `PosterBoard` renders
  /// the lock-screen widget gallery, `chronod` runs widget timelines.
  widgets(
    id: 'widgets',
    displayName: 'Widgets & Live Activities',
    description:
        'Home- and lock-screen widgets, wallpaper posters, and Live '
        'Activities. The largest single saving, and invisible unless you are '
        'developing a widget extension.',
    approxSavingMb: 675,
    labels: _widgets,
  ),

  /// Siri and everything Apple Intelligence dragged in behind it. Second
  /// largest, and the fastest-growing group across iOS releases.
  siri(
    id: 'siri',
    displayName: 'Siri & Apple Intelligence',
    description:
        'Siri, speech recognition and synthesis, on-device language models, '
        'and the suggestion engines that feed them.',
    approxSavingMb: 265,
    labels: _siri,
  ),

  search(
    id: 'search',
    displayName: 'Spotlight & search indexing',
    description:
        'Spotlight and the Core Spotlight index. Disable unless you are '
        'testing what your app donates to search.',
    approxSavingMb: 50,
    labels: _search,
    featureLoss: {
      'com.apple.searchd':
          'Spotlight stops working — pull-to-search finds nothing, and '
          'CoreSpotlight donations are silently dropped.',
    },
  ),

  icloud(
    id: 'icloud',
    displayName: 'iCloud & Apple Account',
    description:
        'Apple Account sign-in, CloudKit, iCloud Drive, keychain sync and '
        'device backup. A simulator that is not signed in still runs all of '
        'it.',
    approxSavingMb: 100,
    labels: _icloud,
    featureLoss: {
      'com.apple.cloudd':
          'CloudKit stops working. Keep this category if your app syncs with '
          'CloudKit or reads an iCloud container.',
    },
  ),

  store(
    id: 'store',
    displayName: 'App Store & purchases',
    description:
        'The App Store, StoreKit, Apple Media Services and the push service '
        'they share.',
    approxSavingMb: 80,
    labels: _store,
    featureLoss: {
      'com.apple.apsd':
          'Push notifications stop arriving entirely — APNs is this daemon. '
          'Keep this category if you test remote notifications.',
      'com.apple.storekitd':
          'StoreKit stops working, so in-app purchase testing (including the '
          'local StoreKit configuration file) fails.',
    },
  ),

  pim(
    id: 'pim',
    displayName: 'Mail, Contacts & Calendar',
    description:
        'Mail, Exchange sync, Contacts, Calendar and Reminders, plus the data '
        'access layer underneath them.',
    approxSavingMb: 80,
    labels: _pim,
    featureLoss: {
      'com.apple.contactsd':
          'The Contacts picker (`CNContactPickerViewController`) will not '
          'present, and Contacts reads return nothing.',
      'com.apple.calaccessd':
          'EventKit and the Calendar picker stop working.',
    },
  ),

  web(
    id: 'web',
    displayName: 'Safari & web services',
    description:
        'Safari sync, Safe Browsing, web push, and the associated-domains '
        'checker.',
    approxSavingMb: 50,
    labels: _web,
    featureLoss: {
      'com.apple.swcd':
          'Universal links and associated domains stop resolving — a '
          'universal link opens Safari instead of your app.',
    },
  ),

  family(
    id: 'family',
    displayName: 'Family Sharing & Screen Time',
    description:
        'Family Sharing, ask-to-buy, Screen Time and usage tracking.',
    approxSavingMb: 65,
    labels: _family,
  ),

  health(
    id: 'health',
    displayName: 'Health, Fitness & Home',
    description:
        'HealthKit, the Fitness stack and HomeKit. Large, and entirely idle '
        'unless your app asks for that data.',
    approxSavingMb: 135,
    labels: _health,
    featureLoss: {
      'com.apple.healthd':
          'HealthKit stops working. Keep this category if your app reads or '
          'writes health data.',
      'com.apple.homed':
          'HomeKit stops working.',
    },
  ),

  photos(
    id: 'photos',
    displayName: 'Photos & media analysis',
    description:
        'The photo library, its face/scene analysis passes, and media '
        'streaming.',
    approxSavingMb: 60,
    labels: _photos,
    featureLoss: {
      'com.apple.assetsd':
          'The photo library daemon. `PHPickerViewController` and '
          '`UIImagePickerController` break — the picker opens empty or not at '
          'all, which is the most common surprise from slimming.',
      'com.apple.photoanalysisd':
          'Face, scene and People album analysis stops. Harmless on its own, '
          'but `assetsd` in the same category is not.',
    },
  ),

  apps(
    id: 'apps',
    displayName: 'Bundled apps',
    description:
        'News, Weather, Maps, Tips and Game Center. Keep this if you embed '
        'MapKit and want map tiles and snapshots.',
    approxSavingMb: 90,
    labels: _apps,
    featureLoss: {
      'com.apple.MapKit.SnapshotService':
          'MapKit snapshots fail. Keep this category if your app renders '
          'static map images.',
    },
  ),

  messaging(
    id: 'messaging',
    displayName: 'Messages & FaceTime',
    description:
        'iMessage, FaceTime and the Apple identity service behind them. None '
        'of it works in a simulator anyway.',
    approxSavingMb: 60,
    labels: _messaging,
  ),

  connectivity(
    id: 'connectivity',
    displayName: 'Continuity & accessories',
    description:
        'Handoff, AirPlay-adjacent discovery, Watch pairing, CarPlay and Find '
        'My — all of which need hardware a simulator does not have.',
    approxSavingMb: 65,
    labels: _connectivity,
  ),

  telemetry(
    id: 'telemetry',
    displayName: 'Analytics & diagnostics',
    description:
        'Ad privacy, feedback, crash and analytics reporting, and A/B trial '
        'assignment. Pure overhead on a machine nobody is measuring.',
    approxSavingMb: 105,
    labels: _telemetry,
  ),

  other(
    id: 'other',
    displayName: 'Wallet & miscellaneous',
    description:
        'Wallet, identity verification, business chat and assorted background '
        'daemons with no developer-facing role.',
    approxSavingMb: 195,
    labels: _other,
  );

  const SlimmingCategory({
    required this.id,
    required this.displayName,
    required this.description,
    required this.approxSavingMb,
    required this.labels,
    this.featureLoss = const {},
  });

  /// Stable identifier for persistence. Never derived from [name], so the enum
  /// constant can be renamed without invalidating a saved selection.
  final String id;

  /// What to call this in a UI.
  final String displayName;

  /// One paragraph a developer can decide from.
  final String description;

  /// Rough resident memory this category accounts for, in megabytes.
  ///
  /// **Not additive.** These are medians measured one category at a time;
  /// services share dirty pages and wake each other up, so summing all fifteen
  /// overshoots the ~2.2 GB actually observed. Present them as relative
  /// weights ("widgets is the big one"), never as a total.
  final int approxSavingMb;

  /// The launchd labels this category owns, fully qualified.
  final List<String> labels;

  /// What visibly stops working, keyed by the label that causes it.
  ///
  /// Only entries confirmed by hand are listed. An empty map means "nothing a
  /// developer was likely to be using", not "verified harmless".
  final Map<String, String> featureLoss;

  /// The category whose [id] is [id], or null.
  static SlimmingCategory? byId(String id) {
    for (final category in values) {
      if (category.id == id) return category;
    }
    return null;
  }
}

/// The categories left running by default, as ids.
///
/// The three a Flutter app is most likely to actually need, and the three whose
/// absence is hardest to diagnose from inside the app:
///
/// * `store` — `com.apple.apsd` *is* APNs, so without it remote notifications
///   never arrive and `firebase_messaging` looks broken rather than disabled.
/// * `photos` — `assetsd` backs `image_picker`; the picker opens empty.
/// * `web` — `swcd` resolves associated domains, so a universal link opens
///   Safari instead of the app under test.
///
/// Everything else is off by default. This is a starting point, not a policy:
/// each category can be switched either way, and an app that never touches
/// push, the photo library or universal links should turn these off too.
const List<String> kDefaultSlimmingKept = ['store', 'photos', 'web'];

/// Every label this build will ever write, in either direction.
///
/// **This set is the safety mechanism.** Slimming is an allowlist, never a
/// denylist: [applyDelta] only ever touches keys that are in here, so a typo,
/// a stale saved category id or a bad caller cannot reach a daemon the system
/// cannot live without.
///
/// Disabling `com.apple.SpringBoard`, `com.apple.backboardd`,
/// `com.apple.runningboardd` or `com.apple.mobile.installd` was tried, and
/// produces a half-alive device that is worse than a dead one: `simctl list`
/// still reports **Booted** (so device state is not a health check),
/// `simctl bootstatus -b` never returns, `simctl launch` fails with
/// `FBSOpenApplicationServiceErrorDomain code=5`, and `simctl io screenshot`
/// times out. Those four labels are absent from the table below, and a test
/// asserts they stay absent.
Set<String> get allManagedLabels => _allManagedLabels;

final Set<String> _allManagedLabels = Set.unmodifiable({
  for (final category in SlimmingCategory.values) ...category.labels,
});

/// The categories that list [label]. Usually one; five labels are shared.
Set<SlimmingCategory> categoriesFor(String label) => {
  for (final category in SlimmingCategory.values)
    if (category.labels.contains(label)) category,
};

/// The labels that should be disabled for a given choice.
///
/// [except] names the categories to leave running, [keep] individual labels to
/// leave running regardless of category.
///
/// A handful of labels are listed by two categories on purpose — `passd` is
/// both a Wallet daemon and a Store one, `amsaccountsd` is both iCloud and
/// Store. The rule is that **a label stays enabled if _any_ excepted category
/// lists it**: sparing "store" has to actually leave StoreKit working, and it
/// would not if `other` were still free to disable `passd` out from under it.
Set<String> desiredDisabled({
  Set<SlimmingCategory> except = const {},
  Set<String> keep = const {},
}) {
  final spared = <String>{
    for (final category in except) ...category.labels,
    ...keep,
  };
  return {
    for (final category in SlimmingCategory.values)
      if (!except.contains(category))
        for (final label in category.labels)
          if (!spared.contains(label)) label,
  };
}

/// The feature-loss notes that apply to a given choice, keyed by the label
/// that causes each. Intended to be shown before the button is pressed.
Map<String, String> featureLossFor({
  Set<SlimmingCategory> except = const {},
  Set<String> keep = const {},
}) {
  final disabled = desiredDisabled(except: except, keep: keep);
  return {
    for (final category in SlimmingCategory.values)
      for (final entry in category.featureLoss.entries)
        if (disabled.contains(entry.key)) entry.key: entry.value,
  };
}

/// Merges [desired] into the labels already in a device's `disabled.plist`.
///
/// The plist is tri-state — `true` disabled, `false` explicitly enabled, absent
/// enabled by default — and it is **not ours alone**. launchd writes its own
/// entries into it: after one boot here it had added seventeen explicit `false`
/// keys of its own (`com.apple.pairedsyncd`, `com.apple.nanoappregistryd`,
/// `com.apple.security.otpaird`, …). So this is a merge, never a replacement:
/// [existing] must be what was actually read back from the device, and every
/// key that is not in [allManagedLabels] is returned untouched.
///
/// Managed labels move as follows:
///
/// * in [desired] — set to `true` (disabled).
/// * not in [desired], currently `true` — **removed**, restoring the default.
///   Removal rather than an explicit `false` because that is the recovery path
///   that was verified: shut down, drop our keys, boot. `simctl erase` is not
///   needed.
/// * not in [desired], currently `false` — left exactly as found. That value is
///   usually launchd's own, it already means "enabled", and rewriting it would
///   be churn in a file another process owns.
///
/// Anything in [desired] that is not a managed label is ignored. That is the
/// allowlist doing its job, and it is the reason a wrong category id cannot
/// turn into a bricked device.
Map<String, bool> applyDelta(Map<String, bool> existing, Set<String> desired) {
  final next = Map<String, bool>.of(existing);
  for (final label in allManagedLabels) {
    if (desired.contains(label)) {
      next[label] = true;
    } else if (next[label] == true) {
      next.remove(label);
    }
  }
  return next;
}

// ---------------------------------------------------------------------------
// The table. Every label below was confirmed present in a stock iOS 26.5 boot;
// an unknown label is inert to launchd, so a stale entry costs nothing and no
// validation pass is needed.
// ---------------------------------------------------------------------------

const List<String> _widgets = [
  'com.apple.PosterBoard',
  'com.apple.chronod',
  'com.apple.liveactivitiesd',
];

const List<String> _siri = [
  'com.apple.assistantd',
  'com.apple.assistant_cdmd',
  'com.apple.assistant_service',
  'com.apple.siriactionsd',
  'com.apple.siriinferenced',
  'com.apple.siriknowledged',
  'com.apple.sirittsd',
  'com.apple.siri.context.service',
  'com.apple.siri.acousticsignature',
  'com.apple.corespeechd',
  'com.apple.voiced',
  'com.apple.voicebankingd',
  'com.apple.speechmodeltrainingd',
  'com.apple.intelligenceplatformd',
  'com.apple.intelligencecontextd',
  'com.apple.intelligenceflowd',
  'com.apple.intelligencetasksd',
  'com.apple.generativeexperiencesd',
  'com.apple.knowledgeconstructiond',
  'com.apple.naturallanguaged',
  'com.apple.textunderstandingd',
  'com.apple.modelcatalogd',
  'com.apple.modelmanagerd',
  'com.apple.mlhostd',
  'com.apple.mlruntimed',
  'com.apple.suggestd',
  'com.apple.parsecd',
  'com.apple.parsec-fbf',
  'com.apple.proactiveeventtrackerd',
];

const List<String> _search = [
  'com.apple.searchd',
  'com.apple.searchtoold',
  'com.apple.spotlightknowledged',
  'com.apple.spotlightknowledged.updater',
  'com.apple.corespotlightservice',
];

const List<String> _icloud = [
  'com.apple.appleaccountd',
  'com.apple.appleaccounttransparencyd',
  'com.apple.appleidsetupd',
  'com.apple.akd',
  'com.apple.amsaccountsd',
  'com.apple.amsengagementd',
  'com.apple.amsondevicestoraged',
  'com.apple.cloudd',
  'com.apple.cloudphotod',
  'com.apple.ckdiscretionaryd',
  'com.apple.cloudsettingssyncagent',
  'com.apple.bird',
  'com.apple.syncdefaultsd',
  'com.apple.cdpd',
  'com.apple.sosd',
  'com.apple.SecureBackupDaemon',
  'com.apple.TrustedPeersHelper',
  'com.apple.protectedcloudstorage.protectedcloudkeysyncing',
  'com.apple.icloudmailagent',
  'com.apple.icloudsubscriptionoptimizerd',
  'com.apple.communicationtrustd',
];

const List<String> _store = [
  'com.apple.appstored',
  'com.apple.appstorecomponentsd',
  'com.apple.apsd',
  'com.apple.itunescloudd',
  'com.apple.itunesstored',
  'com.apple.storekitd',
  // Also listed by `icloud` — Apple Media Services sits under both.
  'com.apple.amsaccountsd',
  'com.apple.amsengagementd',
  'com.apple.amsondevicestoraged',
  // Also listed by `other` — Wallet is both a store surface and a system app.
  'com.apple.passd',
  'com.apple.financed',
  'com.apple.videosubscriptionsd',
  'com.apple.assetsubscriptiond',
  'com.apple.musicd',
];

const List<String> _pim = [
  'com.apple.email.maild',
  'com.apple.exchangesyncd',
  'com.apple.dataaccess.dataaccessd',
  'com.apple.calaccessd',
  'com.apple.remindd',
  'com.apple.contactsd',
  'com.apple.contacts.postersyncd',
  'com.apple.peopled',
];

const List<String> _web = [
  'com.apple.SafariBookmarksSyncAgent',
  'com.apple.Safari.History',
  'com.apple.Safari.passwordbreachd',
  'com.apple.Safari.SafeBrowsing.Service',
  'com.apple.safarifetcherd',
  'com.apple.WebBookmarks.webbookmarksd',
  'com.apple.webkit.adattributiond',
  'com.apple.webkit.webpushd',
  'com.apple.webprivacyd',
  'com.apple.swcd',
];

const List<String> _family = [
  'com.apple.familycircled',
  'com.apple.FamilyControlsAgent',
  'com.apple.familynotification',
  'com.apple.askpermissiond',
  'com.apple.asktod',
  'com.apple.ScreenTimeAgent',
  'com.apple.ScreenTimeSettingsAgent',
  'com.apple.UsageTrackingAgent',
];

const List<String> _health = [
  'com.apple.healthd',
  'com.apple.healthappd',
  'com.apple.healthcontentd',
  'com.apple.healtheventsd',
  'com.apple.healthrecordsd',
  'com.apple.finhealthd',
  'com.apple.homed',
  'com.apple.homeeventsd',
  'com.apple.fitcore',
  'com.apple.fitcore.session',
  'com.apple.fitnesscoachingd',
  'com.apple.fitnessintelligenced',
  'com.apple.activityawardsd',
  'com.apple.activitysharingd',
];

const List<String> _photos = [
  'com.apple.photoanalysisd',
  'com.apple.photosface',
  'com.apple.mediaanalysisd',
  'com.apple.mediaanalysisd.service',
  'com.apple.mediastream.mstreamd',
  'com.apple.medialibraryd',
  'com.apple.assetsd',
  'com.apple.assetsd.nebulad',
];

const List<String> _apps = [
  'com.apple.newsd',
  'com.apple.weatherd',
  'com.apple.Maps.mapssyncd',
  'com.apple.Maps.mapspushd',
  'com.apple.Maps.geocorrectiond',
  'com.apple.maps.destinationd',
  'com.apple.MapKit.SnapshotService',
  'com.apple.jetpackassetd',
  'com.apple.tipsd',
  'com.apple.gamed',
  'com.apple.gamesaved',
  'com.apple.GameController.gamecontrollerd',
];

const List<String> _messaging = [
  'com.apple.identityservicesd',
  'com.apple.ids_simd',
  'com.apple.imautomatichistorydeletionagent',
  'com.apple.imcore.imtransferagent',
  'com.apple.imdpersistence.IMDPersistenceAgent',
  'com.apple.facetimemessagestored',
  'com.apple.telephonyutilities.callservicesd',
];

const List<String> _connectivity = [
  'com.apple.rapportd',
  'com.apple.companiond',
  'com.apple.carkitd',
  'com.apple.wcd',
  'com.apple.tvremoted',
  'com.apple.avatarsd',
  'com.apple.stickersd',
  'com.apple.sociallayerd',
  'com.apple.announced',
  'com.apple.navd',
  'com.apple.findmy.findmylocated',
];

const List<String> _telemetry = [
  'com.apple.ap.adprivacyd',
  'com.apple.ap.promotedcontentd',
  'com.apple.diagnosticextensionsd',
  'com.apple.feedbackd',
  'com.apple.rtcreportingd',
  'com.apple.securityuploadd',
  'com.apple.geoanalyticsd',
  'com.apple.triald',
  'com.apple.followupd',
  'com.apple.purplebuddy.budd',
  'com.apple.devicecheckd',
];

const List<String> _other = [
  // Both also listed by `store`; see the note there.
  'com.apple.financed',
  'com.apple.passd',
  'com.apple.merchantd',
  'com.apple.coreidvd',
  'com.apple.businessservicesd',
  'com.apple.deviceaccessd',
  'com.apple.replicatord',
  'com.apple.linkd',
  'com.apple.ind',
  'com.apple.storagedatad',
  'com.apple.StatusKitAgent',
  'com.apple.countryd',
  'com.apple.mobileassetd',
  'com.apple.managedconfiguration.passcodenagd',
];
