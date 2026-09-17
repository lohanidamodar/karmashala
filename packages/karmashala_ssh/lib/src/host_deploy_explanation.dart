import 'package:meta/meta.dart';

import 'host_deployment.dart';
import 'privileged_command.dart';

/// What the button beside a deploy failure does. All three run the one deploy;
/// the word is what a person expects it to be called at that moment.
enum HostDeployAction {
  install('Install'),
  update('Update'),
  retry('Retry'),

  /// Nothing to press: the machine is one the host does not run on.
  none('');

  const HostDeployAction(this.label);
  final String label;
}

/// A deploy that did not end `ready`, as a person is told it: what happened,
/// what to do about it, and the button that does it.
@immutable
class HostDeployExplanation {
  const HostDeployExplanation({
    required this.sentence,
    required this.remedy,
    required this.action,
    this.command,
    this.privileged,
  });

  final String sentence;
  final String remedy;
  final HostDeployAction action;

  /// Something to run on *this* computer — building a missing bundle.
  final String? command;

  /// Something root has to run on the machine first.
  final PrivilegedCommand? privileged;
}

/// [deployment] in words, for every surface that shows one. [debugRun] adds
/// the build command, which means nothing to somebody running a release.
HostDeployExplanation explainHostDeployment(
  HostDeployment deployment, {
  required String hostName,
  bool debugRun = false,
}) {
  final platform = deployment.platform;
  switch (deployment.status) {
    case HostDeploymentStatus.ready:
      return HostDeployExplanation(
        sentence: deployment.reason,
        remedy: '',
        action: HostDeployAction.none,
      );
    case HostDeploymentStatus.noBinary:
      final wanted = platform?.targetKey ?? 'its platform';
      final have = deployment.availableTargets;
      return HostDeployExplanation(
        sentence:
            'This build of Karmashala carries no session host for $hostName, '
            'which is ${platform == null ? 'a machine it could not read' : '$platform'} — '
            '${have.isEmpty ? 'it carries none at all' : 'it carries ${have.join(', ')} only'}.',
        remedy:
            'Use a Karmashala build that ships the $wanted host bundle beside '
            'the app, then choose Retry.'
            '${debugRun ? ' On a debug run, build it yourself with the command below.' : ''}',
        action: HostDeployAction.retry,
        command: debugRun && platform != null && platform.isLinux
            ? hostBundleBuildCommand(platform)
            : null,
      );
    case HostDeploymentStatus.unsupportedPlatform:
      return HostDeployExplanation(
        sentence: deployment.reason,
        remedy:
            'Panes on $hostName use tmux instead. A relay, or a phone paired '
            'with it, needs a glibc Linux machine.',
        action: HostDeployAction.none,
      );
    case HostDeploymentStatus.cannotInstall:
      return HostDeployExplanation(
        sentence: deployment.reason,
        remedy: deployment.privileged == null
            ? 'Make room or fix the home directory on $hostName, then choose '
                  'Install. Everything goes under ~/.karmashala; no root is '
                  'needed.'
            : 'Run the command below in a terminal on $hostName, then choose '
                  'Install.',
        action: HostDeployAction.install,
        privileged: deployment.privileged,
      );
    case HostDeploymentStatus.cannotStart:
      return HostDeployExplanation(
        sentence: deployment.reason,
        remedy:
            'Its own words are in ~/.karmashala/host.log on $hostName. Choose '
            'Retry once that is dealt with.',
        action: HostDeployAction.retry,
      );
    case HostDeploymentStatus.protocolMismatch:
      return HostDeployExplanation(
        sentence: deployment.reason,
        remedy:
            'End the sessions the old host holds ("Sessions on this host…"), '
            'then choose Update: it is only replaced when it holds none.',
        action: HostDeployAction.update,
      );
    case HostDeploymentStatus.unknown:
      return HostDeployExplanation(
        sentence: deployment.reason,
        remedy:
            'Check that $hostName is reachable over SSH, then choose Retry.',
        action: HostDeployAction.retry,
      );
  }
}

/// What builds the bundle a debug run is missing, into the second place
/// `DirectoryHostBinaries.standard` looks. From macOS or Linux — a bundle
/// cross-built on Windows cannot open a store (PROJECT.md §22).
String hostBundleBuildCommand(
  HostPlatform platform, {
  // The filename's version has to start with a digit to be recognised.
  String version = '0.0.0',
}) {
  final arch = platform.architecture;
  return 'dart build cli -t packages/host/bin/karmashala_host.dart '
      '--target-os=linux --target-arch=$arch -o build/host-linux-$arch && '
      'mkdir -p packages/host/build && '
      'tar -czf packages/host/build/karmashala_host-$version-linux-$arch.tar.gz '
      '-C build/host-linux-$arch/bundle .';
}

/// A deploy that did not end with a host to use, carrying the reading. Thrown
/// where a `StateError` used to be, so nothing shows "Bad state:" to a person
/// and every surface can offer the remedy's button.
class HostDeployFailure implements Exception {
  const HostDeployFailure({required this.hostName, required this.deployment});

  final String hostName;
  final HostDeployment deployment;

  HostDeployExplanation explain({bool debugRun = false}) =>
      explainHostDeployment(deployment, hostName: hostName, debugRun: debugRun);

  @override
  String toString() {
    final said = explain();
    return said.remedy.isEmpty
        ? said.sentence
        : '${said.sentence} ${said.remedy}';
  }
}
