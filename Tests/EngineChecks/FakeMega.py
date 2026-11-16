#!/usr/bin/python3
"""Disposable MEGAcmd fixture. Never connects to a network or reads user accounts."""
import sys, os, json, time, signal
from pathlib import Path
root = Path(__file__).parent
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as f:
    f.write(json.dumps(args) + '\n')
mode = (root / 'mode').read_text() if (root / 'mode').exists() else 'success'
if args[0] == 'ls':
    print('FLAGS VERS SIZE DATE HANDLE NAME')
    if mode == 'browse':
        if '-R' in args:
            print('/Photos: ')
            print('/Photos:')
            print('---- 1 32 1730000000 H:ABCDEFGH sample.bin')
        elif args[-1] in ('/Photos', 'H:PHOTOS00'):
            print('/Photos: ')
            print('d--- - - 1730000000 H:TRIPS000 Trips')
        elif args[-1] != '/Photos/Trips':
            print('d--- - - 1730000000 H:PHOTOS00 Photos')
            print('d--- - - 1730000000 H:DOCS0000 Documents')
            print('---- 1 32 1730000000 H:ABCDEFGH sample.bin')
    elif mode == 'folder':
        print('d--- - - 1730000000 H:ABCDEFGH folder')
    else:
        size = 33 if mode == 'changed' else 32
        print(f'---- 1 {size} 1730000000 {args[-1]} sample.bin')
elif args[0] == 'transfers':
    own = root / 'owned.json'
    if '-c' in args:
        tag = args[args.index('-c') + 1]
        if tag != '42' or '-a' in args:
            print('Attempted to cancel an unrelated transfer', file=sys.stderr)
            sys.exit(90)
        if mode == 'cancel-fails':
            sys.exit(1)
        if own.exists():
            own.unlink()
    else:
        print('TAG|DESTINYPATH')
        print(f'7|{root}/unrelated/user-download.bin')
        if own.exists():
            print(f'42|{json.loads(own.read_text())}')
elif args[0] == 'get':
    slot = Path(args[-1])
    (root / 'owned.json').write_text(json.dumps(str(slot / 'sample.bin')))
    (root / 'get-started').write_text('started')
    if mode in ('hang', 'cancel-fails', 'low-space'):
        while True:
            time.sleep(0.05)
    if mode == 'controlled':
        while not (root / 'allow-get').exists() and not (root / ('allow-get-' + args[-2].replace(':', ''))).exists():
            time.sleep(0.02)
    if mode == 'exit-before-loop':
        sys.exit(12)  # Transfer service remains active after the client exits.
    (slot / 'sample.bin').write_bytes(b'x' * 32)
    (root / 'owned.json').unlink(missing_ok=True)
elif args[0] == 'unresponsive-command':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(0.05)
else:
    sys.exit(99)
