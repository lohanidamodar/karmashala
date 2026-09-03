import 'command_runner.dart';

/// Whether a WSL distribution can start Windows programs.
///
/// **This is the single point of failure behind a whole class of symptoms.**
/// Interop is a `binfmt_misc` registration inside the distribution that hands
/// any file starting with `MZ` — every Windows executable — to `/init`. When
/// that registration is gone, `posix_spawn` of a `.exe` fails with `ENOEXEC`,
/// and it fails for *everything*: an agent's MCP servers, `cmd.exe`, a build
/// script's `dart.exe`. On 2026-09-03 it vanished three times on the owner's
/// machine and an agent session silently lost every tool it had for over an
/// hour, while the app went on reporting that its bridge was installed.
///
/// So it is checked once and named as its own row, rather than being inferred
/// from whichever of its victims happened to be probed.
enum WslInteropState {
  /// A handler is registered and enabled. Windows programs run.
  registered,

  /// A handler is registered but switched off (`echo 0 > .../WSLInterop`).
  disabled,

  /// No handler at all — today's failure, and also what `[interop] enabled =
  /// false` in `/etc/wsl.conf` looks like from here.
  missing,

  /// The distribution did not answer, so nothing was learned. **Not** a pass.
  unknown,
}

/// Marks the lines of [wslInteropRequest]'s output as ours.
///
/// The same reason `kEnvMarker` exists: a shell can print things nobody asked
/// for, and reading a verdict off a line number would let a banner decide
/// whether interop is registered.
const String kInteropMarker = '__karmashala_interop:';

/// Both names the handler has gone by. WSL registered `WSLInterop` for years
/// and newer builds register `WSLInterop-late` instead (it is installed after
/// the distribution's own binfmt entries so those win); a machine can have
/// either, and a check that knew only one would report a healthy distribution
/// as broken.
const List<String> kInteropHandlerNames = ['WSLInterop', 'WSLInterop-late'];

/// Command that reports the interop registration inside a distribution.
///
/// `sh`, not a login shell: nothing here needs the user's `PATH`, and a login
/// shell would add both its startup cost and its output to a check whose whole
/// value is being cheap enough to run beside four others.
CommandRequest wslInteropRequest() => CommandRequest(
  executable: 'sh',
  arguments: [
    '-c',
    'd=/proc/sys/fs/binfmt_misc; '
        'for n in ${kInteropHandlerNames.join(' ')}; do '
        '[ -e "\$d/\$n" ] && '
        'printf \'$kInteropMarker%s=%s\\n\' "\$n" "\$(head -n1 "\$d/\$n")"; '
        'done; '
        'printf \'${kInteropMarker}checked=1\\n\'',
  ],
);

/// Reads [wslInteropRequest]'s output.
///
/// Returns [WslInteropState.unknown] when the trailing `checked` marker is
/// absent: without it the command did not run to the end, and "no handler line"
/// would be indistinguishable from "no output at all".
WslInteropState parseWslInterop(String stdout) {
  // `wsl.exe` output can arrive UTF-16-ish, with interleaved NULs and a BOM.
  final cleaned = String.fromCharCodes(
    stdout.codeUnits.where((c) => c != 0x00 && c != 0xFEFF),
  );
  var checked = false;
  var found = false;
  var enabled = false;
  for (final raw in cleaned.split(RegExp(r'[\r\n]+'))) {
    final line = raw.trim();
    if (!line.startsWith(kInteropMarker)) continue;
    final body = line.substring(kInteropMarker.length);
    final split = body.indexOf('=');
    if (split <= 0) continue;
    final name = body.substring(0, split);
    final value = body.substring(split + 1).trim();
    if (name == 'checked') {
      checked = true;
      continue;
    }
    if (!kInteropHandlerNames.contains(name)) continue;
    found = true;
    // `head -n1` of a binfmt entry prints `enabled` or `disabled`. Either
    // handler being live is enough — they register the same `MZ` magic.
    if (value == 'enabled') enabled = true;
  }
  if (!checked) return WslInteropState.unknown;
  if (!found) return WslInteropState.missing;
  return enabled ? WslInteropState.registered : WslInteropState.disabled;
}

/// The line that puts the handler back, for the duration of this boot.
///
/// Registering `MZ` magic against `/init` is what WSL itself does at start-up;
/// running it by hand is the documented recovery and needs root inside the
/// distribution. It does not survive a `wsl --shutdown`, which is the honest
/// thing to say about it rather than presenting it as a fix.
const String kWslInteropRepairCommand =
    'sudo sh -c \'echo ":WSLInterop:M::MZ::/init:PF" '
    '> /proc/sys/fs/binfmt_misc/register\'';
