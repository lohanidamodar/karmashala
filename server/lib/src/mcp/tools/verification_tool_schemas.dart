/// MCP tool definitions for verification runs, served alongside the browser and
/// device tools. Five of them — start, note, finish, list, get — because the
/// driving comes from the tools the agent already has.
const List<Map<String, Object?>> verificationToolSchemas = [
  {
    'name': 'verification_start',
    'description':
        'Begin recording a verification run — a durable, inspectable record '
        'that a change actually works, which you can hand to the human. Give '
        'EXACTLY ONE of: url (a browser run: attaches to the browser, goes '
        'there, and starts watching the console and network), serial (+ '
        'optional package: a device run, which brings that app to the front), '
        'or change:true (a review run: nothing is driven, and the record is '
        'what you read in the diff). While a browser or device run is '
        'recording, every browser_* and device_* call you make is captured as '
        'a step with its screenshots; console errors, failed requests and the '
        'log slice are collected for you at the end. Drive the change the way '
        'a user would, then call verification_finish with a verdict. One run '
        'at a time. Pass sessionId when you are checking someone else\'s '
        'work: it is what makes the verdict count as an independent one '
        'rather than a self-graded pass.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'url': {
          'type': 'string',
          'description':
              'The page to verify, e.g. "localhost:3000/settings". Makes this '
              'a browser run.',
        },
        'serial': {
          'type': 'string',
          'description':
              'Device serial from list_devices. Makes this a device run.',
        },
        'change': {
          'type': 'boolean',
          'description':
              'Makes this a review run: the subject is a code change rather '
              'than a page or a device, so nothing is attached to and nothing '
              'is collected for you. Write what you find with '
              'verification_note, and finish with a verdict — a review that '
              'found nothing is a pass with a reason, never silence.',
        },
        'package': {
          'type': 'string',
          'description':
              'Android package to verify, e.g. "com.example.app". It is '
              'launched at the start of the run, and the closing logcat slice '
              'is filtered to it. Without it, the run records the device but '
              'collects no log.',
        },
        'title': {
          'type': 'string',
          'description':
              'What is being verified, in one line — "the settings page saves '
              'on Enter". Defaults to the target.',
        },
        'sessionId': {
          'type': 'string',
          'description':
              'The session whose WORK is being verified, from list_sessions — '
              'not yours. Defaults to yours, which is the self-graded case. '
              'Attaching it is what lets the human find the evidence from the '
              'conversation, and naming someone else\'s session is what makes '
              'the verdict independent.',
        },
        'launch': {
          'type': 'boolean',
          'description':
              'Device runs only: set false to verify the app already on '
              'screen instead of relaunching it. Default true.',
        },
      },
    },
  },
  {
    'name': 'verification_note',
    'description':
        'Add your own step to the running verification — what you are about '
        'to check, or what you observed that the tools cannot see ("the '
        'spinner never stopped"). Notes are what turn a list of clicks into '
        'an argument.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'text': {'type': 'string', 'description': 'One line. Required.'},
        'detail': {
          'type': 'string',
          'description': 'Anything longer — an expected value, a stack trace.',
        },
      },
      'required': ['text'],
    },
  },
  {
    'name': 'verification_finish',
    'description':
        'Close the run with a verdict and the reason for it, collect the '
        'closing evidence (a screenshot, the console errors, the failed '
        'requests, the logcat slice, the UI tree) and write a markdown report '
        'next to the artifacts. Use "inconclusive" honestly — a run that '
        'could not reach the page is not a fail.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'verdict': {
          'type': 'string',
          'enum': ['pass', 'fail', 'inconclusive'],
          'description': 'Required.',
        },
        'reason': {
          'type': 'string',
          'description':
              'One or two sentences saying what you observed that justifies '
              'the verdict. This is the part a human reads first.',
        },
      },
      'required': ['verdict'],
    },
  },
  {
    'name': 'verification_list',
    'description':
        'List recorded verification runs, newest first — one line each with '
        'the verdict, the target and the step count.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Only runs attached to this session.',
        },
        'limit': {
          'type': 'number',
          'description': 'How many runs to show. Default 20.',
        },
      },
    },
  },
  {
    'name': 'verification_get',
    'description':
        'Read one run: its verdict, its steps and what it captured. Compact by '
        'default — step summaries and a list of artifacts, no images and no '
        'file contents. Pass full:true for step detail and the text of the '
        'evidence files, or images:true to attach the screenshots. Ask for '
        'images only when you need to look at one; they are the expensive part. '
        'It also says which code the run was taken on (commit and uncommitted '
        'files) and whether the checkout still holds it: FRESH, STALE (the '
        'code changed since, or while it ran) or VERSION UNKNOWN. A stale pass '
        'is not a pass for the code as it is now.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description':
              'Run id, or a unique prefix of one. Omit for the run that is '
              'recording now.',
        },
        'full': {
          'type': 'boolean',
          'description':
              'Include step detail and the contents of text artifacts.',
        },
        'images': {
          'type': 'boolean',
          'description': 'Attach the screenshots as images.',
        },
      },
    },
  },
];
