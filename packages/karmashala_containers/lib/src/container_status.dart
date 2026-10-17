/// Where a container stands, as `docker inspect` says.
enum ContainerState {
  running,
  stopped,
  starting,
  paused,

  /// Docker has no container by that name any more.
  missing,

  /// The host could not be asked.
  unknown,
}

/// The state in [output] of the status script, which prints Docker's
/// `.State.Status` or `missing`.
ContainerState parseContainerState(String output) =>
    switch (output.trim().split('\n').first.trim()) {
      'running' => ContainerState.running,
      'exited' || 'created' || 'dead' => ContainerState.stopped,
      'restarting' => ContainerState.starting,
      'paused' => ContainerState.paused,
      'missing' => ContainerState.missing,
      _ => ContainerState.unknown,
    };
