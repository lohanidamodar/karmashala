import 'github_release.dart';

/// How this copy of Karmashala was installed, which decides what an update
/// does.
enum InstallKind {
  /// Inno Setup put it in place: its `unins*.exe` sits beside the exe.
  windowsInstaller,

  /// The portable zip, unpacked wherever the person chose.
  windowsPortable,

  /// Running from an AppImage (`APPIMAGE` is set).
  linuxAppImage,

  /// The tarball, unpacked.
  linuxTarball,

  macos,

  /// Installed by Google Play: Play's own flexible update covers it.
  androidPlay,

  /// An APK installed by hand or by another store.
  androidSideloaded,

  /// iOS, the web, or anything else: no update path here.
  unsupported;

  /// Whether GitHub's releases are where this install's updates come from.
  bool get usesGitHub => switch (this) {
    androidPlay || unsupported => false,
    _ => true,
  };
}

/// Google Play's package name, as the install source names it.
const kPlayStoreInstaller = 'com.android.vending';

/// What the running process can see about where it came from.
final class InstallFacts {
  const InstallFacts({
    required this.os,
    this.namesBesideExecutable = const [],
    this.appImage,
    this.androidInstallerKnown = false,
    this.androidInstaller,
  });

  /// `Platform.operatingSystem`, or `web`.
  final String os;

  /// The file names in the executable's folder (Windows).
  final List<String> namesBesideExecutable;

  /// The `APPIMAGE` environment variable: the AppImage's own path.
  final String? appImage;

  /// Whether Android answered the install-source question at all.
  final bool androidInstallerKnown;

  /// The package that installed this app, when Android named one.
  final String? androidInstaller;
}

final _uninstaller = RegExp(r'^unins\d*\.exe$', caseSensitive: false);

InstallKind detectInstallKind(InstallFacts facts) => switch (facts.os) {
  'windows' =>
    facts.namesBesideExecutable.any(_uninstaller.hasMatch)
        ? InstallKind.windowsInstaller
        : InstallKind.windowsPortable,
  'linux' =>
    (facts.appImage?.isNotEmpty ?? false)
        ? InstallKind.linuxAppImage
        : InstallKind.linuxTarball,
  'macos' => InstallKind.macos,
  // An unanswered question keeps the Play flow alone: offering an APK over
  // a Play install would swap its update source behind the person's back.
  'android' =>
    !facts.androidInstallerKnown ||
            facts.androidInstaller == kPlayStoreInstaller
        ? InstallKind.androidPlay
        : InstallKind.androidSideloaded,
  _ => InstallKind.unsupported,
};

/// What pressing Update does.
enum UpdateMethod {
  /// Download the setup, verify it, run it silently and quit.
  runInstaller,

  /// Download beside the AppImage, verify it, swap it in, offer Restart.
  replaceAppImage,

  /// Download the DMG, verify it and open it.
  openDiskImage,

  /// Open the APK's download link: Android's installer takes it from there.
  openApk,

  /// Open the release page; the person updates by hand.
  openReleasePage,
}

final class UpdatePlan {
  const UpdatePlan(this.method, {this.asset});

  final UpdateMethod method;

  /// The file it needs, for every method but [UpdateMethod.openReleasePage].
  final ReleaseAsset? asset;

  /// Whether the file is downloaded and verified here before anything runs.
  bool get downloads => switch (method) {
    UpdateMethod.runInstaller ||
    UpdateMethod.replaceAppImage ||
    UpdateMethod.openDiskImage => true,
    _ => false,
  };
}

/// The release asset each install kind takes, by the release workflow's
/// names; null where it takes none.
String? assetNameFor(InstallKind kind, String version) => switch (kind) {
  InstallKind.windowsInstaller => 'Karmashala-Setup-$version.exe',
  InstallKind.linuxAppImage => 'Karmashala-$version-x86_64.AppImage',
  InstallKind.macos => 'Karmashala-macOS-$version.dmg',
  InstallKind.androidSideloaded => 'Karmashala-android-$version.apk',
  _ => null,
};

/// What updating [kind] to [release] does, or null where GitHub is not this
/// install's source. A release missing the expected file falls back to its
/// page rather than to nothing.
UpdatePlan? planUpdate(InstallKind kind, GitHubRelease release) {
  if (!kind.usesGitHub) return null;
  final name = assetNameFor(kind, release.versionText);
  final asset = name == null ? null : release.asset(name);
  if (asset == null) return const UpdatePlan(UpdateMethod.openReleasePage);
  return UpdatePlan(switch (kind) {
    InstallKind.windowsInstaller => UpdateMethod.runInstaller,
    InstallKind.linuxAppImage => UpdateMethod.replaceAppImage,
    InstallKind.macos => UpdateMethod.openDiskImage,
    _ => UpdateMethod.openApk,
  }, asset: asset);
}

/// What the silent setup is started with. `/KARMASHALARESTART` has the
/// script's `[Run]` entry start the app again once it is done.
const kInstallerArguments = [
  '/SILENT',
  '/SUPPRESSMSGBOXES',
  '/NORESTART',
  '/KARMASHALARESTART',
];
