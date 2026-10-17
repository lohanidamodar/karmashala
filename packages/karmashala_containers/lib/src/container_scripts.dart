import 'container_options.dart';
import 'shell_quote.dart';

/// Printed by the setup once sshd is about to start.
const kReadyMarker = 'KARMASHALA-READY';

/// Printed by the setup when a step failed; the container is then removed.
const kFailedMarker = 'KARMASHALA-FAILED';

/// The setup a container runs as its command, every start: the user, key-only
/// sshd and sudo once; Node and the chosen CLIs once; the key every time; then
/// sshd in the foreground. Its parameters arrive as `KS_*` environment
/// variables, never inside its text.
const containerSetupScript = r'''
set -eu
trap 'echo KARMASHALA-FAILED' EXIT
say() { echo "karmashala: $*"; }
U="$KS_USER"
mkdir -p /etc/karmashala

pm=
for c in apt-get dnf apk pacman; do
  if command -v "$c" >/dev/null 2>&1; then pm=$c; break; fi
done
[ -n "$pm" ] || { say "no apt, dnf, apk or pacman in this image"; exit 1; }

install_pkgs() {
  case "$pm" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$@" ;;
    dnf) dnf install -y -q --allowerasing "$@" ;;
    apk) apk add --no-cache -q "$@" ;;
    pacman) pacman -S --noconfirm --needed "$@" ;;
  esac
}

if [ ! -f /etc/karmashala/base-done ]; then
  say "installing ssh, sudo, curl and git with $pm"
  case "$pm" in
    apt-get) apt-get update -q
      install_pkgs openssh-server sudo curl git ca-certificates bash xz-utils ;;
    dnf) install_pkgs openssh-server sudo curl git ca-certificates bash xz shadow-utils procps-ng ;;
    apk) install_pkgs openssh sudo curl git ca-certificates bash xz shadow ;;
    pacman) pacman -Syu --noconfirm
      install_pkgs openssh sudo curl git ca-certificates bash xz ;;
  esac
  say "creating $U with sudo and key-only ssh"
  id "$U" >/dev/null 2>&1 || useradd -M -d "/home/$U" -s /bin/bash "$U"
  usermod -p '*' "$U"
  mkdir -p /etc/sudoers.d
  echo "$U ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/karmashala
  chmod 440 /etc/sudoers.d/karmashala
  ssh-keygen -A >/dev/null
  conf=/etc/ssh/sshd_config
  { printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n'
    printf 'PermitRootLogin no\nPubkeyAuthentication yes\nAllowUsers %s\n' "$U"
    cat "$conf"; } > "$conf.ks" && mv "$conf.ks" "$conf"
  touch /etc/karmashala/base-done
fi

mkdir -p "/home/$U/.ssh" /run/sshd
printf '%s\n' "$KS_PUBKEY" > "/home/$U/.ssh/authorized_keys"
chown "$U" "/home/$U" "/home/$U/.ssh" "/home/$U/.ssh/authorized_keys"
chmod 755 "/home/$U"
chmod 700 "/home/$U/.ssh"
chmod 600 "/home/$U/.ssh/authorized_keys"

node_major() {
  if command -v node >/dev/null 2>&1; then
    node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0
  else
    echo 0
  fi
}

node_from_nodejs_org() {
  case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) say "no Node build for $(uname -m)"; return 1 ;;
  esac
  base=https://nodejs.org/dist/latest-v22.x
  sums=$(curl -fsSL "$base/SHASUMS256.txt")
  name=$(printf '%s\n' "$sums" | awk -v want="linux-$arch.tar.xz" '$2 ~ want"$" {print $2; exit}')
  [ -n "$name" ] || { say "nodejs.org lists no $arch build"; return 1; }
  say "installing Node from nodejs.org ($name)"
  curl -fsSL -o /tmp/node.tar.xz "$base/$name"
  sum=$(printf '%s\n' "$sums" | awk -v n="$name" '$2 == n {print $1}')
  echo "$sum  /tmp/node.tar.xz" | sha256sum -c - >/dev/null
  tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
  rm -f /tmp/node.tar.xz
}

if [ -n "$KS_AGENTS" ] && [ ! -f /etc/karmashala/agents-done ]; then
  if [ "$(node_major)" -lt "$KS_NODE_MIN" ]; then
    candidate=0
    case "$pm" in
      apt-get) candidate=$(apt-cache policy nodejs | awk '/Candidate:/ {print $2}' | sed 's/^[0-9]*://' | cut -d. -f1) ;;
      dnf) candidate=$(dnf -q repoquery --latest-limit 1 --qf '%{version}' nodejs 2>/dev/null | cut -d. -f1) ;;
      *) candidate=$KS_NODE_MIN ;;
    esac
    case "$candidate" in ''|*[!0-9]*) candidate=0 ;; esac
    if [ "$candidate" -ge "$KS_NODE_MIN" ]; then
      say "installing Node $candidate with $pm"
      install_pkgs nodejs npm
    fi
    if [ "$(node_major)" -lt "$KS_NODE_MIN" ]; then
      say "the distribution's Node is older than $KS_NODE_MIN"
      node_from_nodejs_org
    fi
  fi
  say "installing $KS_AGENTS with npm"
  # shellcheck disable=SC2086
  npm install -g --no-fund --no-audit $KS_AGENTS
  touch /etc/karmashala/agents-done
fi

trap - EXIT
echo KARMASHALA-READY
exec "$(command -v sshd || echo /usr/sbin/sshd)" -D -e
''';

/// The ports a host is listening on and those Docker has published, for
/// `parseListeningPorts`.
const listeningPortsScript = r'''
ss -Htln 2>/dev/null || netstat -tln 2>/dev/null
docker ps --format '{{.Ports}}' 2>/dev/null
true
''';

final _imagePattern = RegExp(r'^[a-z0-9][a-z0-9._/:-]*$');
final _npmPattern = RegExp(r'^@?[a-z0-9][a-z0-9._/-]*$');

String _guardedName(String containerName) {
  if (!containerName.startsWith(kContainerPrefix) ||
      containerNameProblem(containerName.substring(kContainerPrefix.length)) !=
          null) {
    throw ArgumentError.value(
      containerName,
      'containerName',
      'not a container Karmashala made',
    );
  }
  return containerName;
}

/// Pulls [image], printing Docker's progress.
String pullImageScript(String image) {
  if (!_imagePattern.hasMatch(image)) {
    throw ArgumentError.value(image, 'image', 'not an image reference');
  }
  return '${shellAssign('IMAGE', image)}\ndocker pull "\$IMAGE"\n';
}

/// Starts the container [spec] describes, publishing its sshd on
/// `127.0.0.1:[port]` only, and prints its id. Refuses a name already taken;
/// an existing home volume is reused, which is how a recreate keeps files.
String runContainerScript(
  ContainerSpec spec, {
  required int port,
  required String publicKeyLine,
  required String machineId,
}) {
  final name = _guardedName(spec.containerName);
  final image = spec.distro.image;
  final packages = [for (final cli in spec.agents) cli.npmPackage];
  if (!packages.every(_npmPattern.hasMatch)) {
    throw ArgumentError.value(packages, 'agents', 'not npm package names');
  }
  if (publicKeyLine.contains('\n')) {
    throw ArgumentError.value(publicKeyLine, 'publicKeyLine', 'not one line');
  }
  return [
    shellAssign('C', name),
    shellAssign('IMAGE', image),
    shellAssign('VOLUME', spec.homeVolume),
    shellAssign('PORT', '$port'),
    shellAssign('CPUS', '${spec.cpus}'),
    shellAssign('MEMORY', '${spec.memoryMb}m'),
    shellAssign('MACHINE', machineId),
    shellAssign('KS_PUBKEY', publicKeyLine),
    shellAssign('KS_AGENTS', packages.join(' ')),
    shellAssign('KS_NODE_MIN', '${spec.minimumNode}'),
    shellAssign('SETUP', containerSetupScript),
    r'''
if docker inspect "$C" >/dev/null 2>&1; then
  echo "karmashala: a container named $C already exists" >&2
  exit 9
fi
docker run -d --name "$C" --hostname "${C#ks-}" \
  --label dev.karmashala.container=1 --label "dev.karmashala.machine=$MACHINE" \
  --restart unless-stopped --cpus "$CPUS" --memory "$MEMORY" \
  -p "127.0.0.1:$PORT:22" -v "$VOLUME:/home/dev" \
  -e KS_USER=dev -e "KS_PUBKEY=$KS_PUBKEY" -e "KS_AGENTS=$KS_AGENTS" \
  -e "KS_NODE_MIN=$KS_NODE_MIN" \
  "$IMAGE" sh -c "$SETUP"
''',
  ].join('\n');
}

/// Prints the container's setup log as it grows, and exits 0 once it says
/// [kReadyMarker], 3 when it failed or stopped, 4 when the container is gone
/// and 5 after [timeoutSeconds].
String waitForSetupScript(String containerName, {int timeoutSeconds = 1800}) =>
    [
      shellAssign('C', _guardedName(containerName)),
      shellAssign('LIMIT', '${timeoutSeconds ~/ 2}'),
      r'''
log=$(mktemp)
trap 'rm -f "$log"' EXIT
seen=0
i=0
while [ "$i" -lt "$LIMIT" ]; do
  docker logs "$C" > "$log" 2>&1 || { echo "karmashala: the container is gone"; exit 4; }
  total=$(wc -l < "$log")
  if [ "$total" -gt "$seen" ]; then tail -n "+$((seen + 1))" "$log" | head -n "$((total - seen))"; fi
  seen=$total
  grep -q KARMASHALA-READY "$log" && exit 0
  grep -q KARMASHALA-FAILED "$log" && exit 3
  state=$(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null)
  case "$state" in
    running|created) ;;
    *) echo "karmashala: the container is $state"; exit 3 ;;
  esac
  sleep 2
  i=$((i + 1))
done
exit 5
''',
    ].join('\n');

/// Prints Docker's `.State.Status` for the container, or `missing`.
String containerStatusScript(String containerName) => [
  shellAssign('C', _guardedName(containerName)),
  r'''docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null || echo missing''',
].join('\n');

/// Starts the stopped container.
String startContainerScript(String containerName) => [
  shellAssign('C', _guardedName(containerName)),
  r'docker start "$C" >/dev/null',
].join('\n');

/// Stops the container; its restart policy then leaves it stopped.
String stopContainerScript(String containerName) => [
  shellAssign('C', _guardedName(containerName)),
  r'docker stop "$C" >/dev/null',
].join('\n');

/// Deletes the container, only when it carries Karmashala's label, and its
/// home volume too when [withHome]. A container already gone is not an error.
String deleteContainerScript(String containerName, {required bool withHome}) =>
    [
      shellAssign('C', _guardedName(containerName)),
      shellAssign('VOLUME', homeVolumeFor(containerName)),
      shellAssign('WITH_HOME', withHome ? '1' : '0'),
      r'''
if docker inspect "$C" >/dev/null 2>&1; then
  label=$(docker inspect -f '{{index .Config.Labels "dev.karmashala.container"}}' "$C")
  if [ "$label" != 1 ]; then
    echo "karmashala: $C was not made by Karmashala; left alone" >&2
    exit 9
  fi
  docker rm -f -v "$C" >/dev/null
fi
if [ "$WITH_HOME" = 1 ] && docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  docker volume rm "$VOLUME" >/dev/null
fi
''',
    ].join('\n');
