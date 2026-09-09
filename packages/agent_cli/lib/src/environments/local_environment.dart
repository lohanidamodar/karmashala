import 'dart:io';

import './environment_kind.dart';
import './execution_environment.dart';

/// Stable id of the always-present local execution environment — the host the
/// desktop app runs on.
///
/// The literal is `windows` on every platform, and stays that way. It is an
/// opaque database key, never shown to anyone: what a user reads comes from
/// [ExecutionEnvironment.name], and every branch in the app reads
/// [ExecutionEnvironment.kind]. Making it follow the OS was tried and is a bad
/// trade — it orphans every project, session and checkpoint in an existing
/// Windows install behind a key nothing points at any more, to spell a string
/// no one ever sees.
const String localHostEnvironmentId = 'windows';

/// The [EnvironmentKind] of the host this app is running on.
///
/// This — not the id — is what tells the app whether it is looking at a Windows
/// machine, and it is why a Mac now looks its agent CLIs up with `command -v`
/// instead of `where`.
EnvironmentKind get localHostEnvironmentKind => Platform.isWindows
    ? EnvironmentKind.windowsNative
    : EnvironmentKind.localPosix;

/// What the host OS is called wherever a user reads it.
String get localHostEnvironmentName => switch (Platform.operatingSystem) {
  'windows' => 'Windows',
  'macos' => 'macOS',
  _ => 'Linux',
};

/// Builds the local host's [ExecutionEnvironment] record.
ExecutionEnvironment localHostEnvironment(DateTime createdAt) =>
    ExecutionEnvironment(
      id: localHostEnvironmentId,
      kind: localHostEnvironmentKind,
      name: localHostEnvironmentName,
      createdAt: createdAt,
    );

/// The Windows host, as the **target of a translation out of WSL**.
///
/// A WSL distribution only ever sits on a Windows machine, so `/mnt/c/src` and
/// `\\wsl.localhost\Ubuntu\...` are statements about a Windows filesystem no
/// matter which OS is asking. Callers translating a WSL path want this, not
/// [localHostEnvironment] — which is whatever host is running the app, and on a
/// Mac would ask [PathTranslator] to render a Windows drive as a POSIX path.
ExecutionEnvironment windowsHostEnvironment(DateTime createdAt) =>
    ExecutionEnvironment(
      id: localHostEnvironmentId,
      kind: EnvironmentKind.windowsNative,
      name: 'Windows',
      createdAt: createdAt,
    );
