import 'package:meta/meta.dart';

import '../protocol/host_version.dart';
import 'host_deployment.dart';
import 'privileged_command.dart';

/// What the button beside a deploy failure does. All three run the one deploy
/// (at the server); the word is what a person expects it to be called then.
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

  /// Something to run on the server's computer — building a missing bundle.
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
      return HostDeployExplanation(
        sentence: deployment.reason,
        remedy:
            'Put the $wanted host bundle (karmashala_host-<version>-$wanted'
            '.tar.gz) where the Karmashala server looks for bundles, then '
            'choose Retry.'
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
            'Karmashala cannot use $hostName: terminals, agents, a relay and a '
            'phone paired with it all run in the Karmashala host there, which '
            'runs on glibc Linux and macOS only.',
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
      final wanted = platform?.targetKey ?? 'its platform';
      if (deployment.noNewerHost) {
        // Update would install the very host that is stale.
        return HostDeployExplanation(
          sentence: deployment.reason,
          remedy:
              'This build of Karmashala carries no newer host for $wanted '
              'than the ${deployment.offeredVersion ?? 'one'} on $hostName, so '
              'there is nothing to update it to. Rebuild or reinstall '
              'Karmashala with its host bundles, or put '
              'karmashala_host-$kHostVersion-$wanted.tar.gz into '
              '${deployment.bundleFolder ?? 'the host-bundles folder in the Karmashala server\'s data folder'}, '
              'then try again.',
          action: HostDeployAction.retry,
        );
      }
      return HostDeployExplanation(
        sentence: deployment.reason,
        remedy:
            'Its sessions cannot be counted across protocols, so it is not '
            'replaced on its own. Stop it (Stop, on $hostName\'s card in '
            'Settings › Machines; its sessions end with it), and then Update '
            'or Start puts this app\'s host in its place.',
        action: HostDeployAction.update,
      );
    case HostDeploymentStatus.unknown:
      return HostDeployExplanation(
        sentence: deployment.reason,
        remedy:
            'Check that $hostName is reachable over SSH from the Karmashala '
            'server, then choose Retry.',
        action: HostDeployAction.retry,
      );
  }
}

/// What builds the bundle a debug run is missing, into a place the server
/// looks (`server/build`), run from the repository root. From macOS or Linux
/// — a bundle cross-built on Windows cannot open a store (PROJECT.md §22).
String hostBundleBuildCommand(
  HostPlatform platform, {
  // The filename's version has to start with a digit to be recognised.
  String version = '0.0.0',
}) {
  final arch = platform.architecture;
  return 'dart build cli -t server/bin/karmashala_host.dart '
      '--target-os=linux --target-arch=$arch -o build/host-linux-$arch && '
      'mkdir -p server/build && '
      'tar -czf server/build/karmashala_host-$version-linux-$arch.tar.gz '
      '-C build/host-linux-$arch/bundle .';
}

/// A deploy that did not end with a host to use, carrying the reading.
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
