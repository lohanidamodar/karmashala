/// The recording tools the server runs (slice 5b), moved from the app with
/// their names and input schemas unchanged. The server writes a terminal's
/// recording as an asciicast from the session's own bytes — a Karmashala
/// window renders a cast to video — and records the devices of its own
/// machine with their own recorders.
const List<Map<String, Object?>> recordingControlToolSchemas = [
  {
    'name': 'terminal_record_start',
    'description':
        'Start recording a terminal pane. The Karmashala server records the '
        'pane\'s own output from now on, whether or not a window shows it. '
        'Everything printed in the pane is captured, including anything '
        'secret — nothing is redacted. Answers with the formats '
        'terminal_record_stop can produce here, so ask for one that exists.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {
          'type': 'string',
          'description': 'From terminal_list, or terminal_open.',
        },
      },
      'required': ['paneId'],
    },
  },
  {
    'name': 'terminal_record_stop',
    'description':
        'Stop a terminal recording and write it to a file: an asciicast '
        '(.cast) — the pane\'s own bytes with their timing, which asciinema '
        'plays as they are. "mp4", "gif" and "pngSequence" are rendered from '
        'that cast by a Karmashala window, not by the server: this tool writes '
        'the cast and says plainly which of them it did not produce. Answers '
        'with the file, and with isVideo=false, because a cast is not a video.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {'type': 'string'},
        'format': {
          'type': 'string',
          'description': '"mp4", "gif" or "pngSequence".',
        },
      },
      'required': ['paneId'],
    },
  },
  {
    'name': 'device_record_start',
    'description':
        'Start recording the screen of a device on the Karmashala server\'s '
        'machine — the one this session holds, else the only one ready. An '
        'Android device records itself with its own screenrecord (MP4, at '
        'most 180 seconds, then it stops on its own); a simulator with '
        'simctl (a QuickTime movie). "mp4" is the file every player opens; '
        '"ts" (MPEG-TS) is only what a device pane\'s live view records, and '
        'is refused here.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'format': {'type': 'string', 'description': '"mp4" or "ts".'},
      },
    },
  },
  {
    'name': 'device_record_stop',
    'description':
        'Stop the device screen recording and say what became of it — the '
        'file, or why there is none. A recording that caught no frame reports '
        '"empty" and leaves no file behind rather than a container header no '
        'player opens.',
    'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
  },
];
