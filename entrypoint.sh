#!/bin/bash
set -e

echo "── Aura Agent starting ──"

# ── 1. Authentication ──
if [ "${CLI_TOOL:-claude}" = "claude" ]; then
    if claude auth status > /dev/null 2>&1; then
        echo "✓ Claude Code: authenticated"
    else
        echo "⏳ Claude Code: not authenticated, starting login flow..."

        # Run claude auth login, capture the OAuth URL, feed the code back
        python3 -c "
import asyncio, os, sys, json, time, urllib.request, urllib.error

AURA_URL = os.environ.get('AURA_URL', '').rstrip('/')
AURA_API_KEY = os.environ.get('AURA_API_KEY', '')
CONTAINER_ID = os.environ.get('CONTAINER_ID', '')

def aura_post(path, data):
    req = urllib.request.Request(
        f'{AURA_URL}{path}',
        data=json.dumps(data).encode(),
        headers={'Authorization': f'Bearer {AURA_API_KEY}', 'Content-Type': 'application/json'},
        method='POST')
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f'  warning: POST {path} failed: {e}', file=sys.stderr)

def aura_get(path):
    req = urllib.request.Request(
        f'{AURA_URL}{path}',
        headers={'Authorization': f'Bearer {AURA_API_KEY}'})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except Exception as e:
        print(f'  warning: GET {path} failed: {e}', file=sys.stderr)
        return {}

async def main():
    proc = await asyncio.create_subprocess_exec(
        'claude', 'auth', 'login',
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        stdin=asyncio.subprocess.PIPE)

    login_url = None

    # Read stdout line by line until we find the URL
    while True:
        try:
            line = await asyncio.wait_for(proc.stdout.readline(), timeout=30)
        except asyncio.TimeoutError:
            break
        if not line:
            break
        text = line.decode().strip()
        if text:
            print(f'  [claude] {text}')
        if 'http' in text:
            for word in text.split():
                if word.startswith('http'):
                    login_url = word
        if login_url:
            break

    if not login_url:
        print('ERROR: Could not capture OAuth URL from claude auth login')
        sys.exit(1)

    # Post URL to Aura
    print(f'  Auth URL captured, posting to Aura...')
    aura_post(f'/api/containers/{CONTAINER_ID}/auth-url', {'url': login_url})

    # Poll Aura for the auth code
    print(f'  Waiting for auth code from Aura UI...')
    code = None
    while code is None:
        time.sleep(2)
        result = aura_get(f'/api/containers/{CONTAINER_ID}/auth-code')
        code = result.get('authCode') or result.get('code') or result.get('Code')

    # Feed the code to claude auth login
    print(f'  Code received, submitting to Claude Code...')
    proc.stdin.write((code + '\n').encode())
    await proc.stdin.drain()
    proc.stdin.close()

    # Wait for completion
    try:
        stdout_rest, stderr_rest = await asyncio.wait_for(proc.communicate(), timeout=30)
        if stdout_rest:
            for l in stdout_rest.decode().splitlines():
                if l.strip():
                    print(f'  [claude] {l.strip()}')
    except asyncio.TimeoutError:
        proc.kill()
        print('ERROR: claude auth login timed out after receiving code')
        sys.exit(1)

    if proc.returncode != 0:
        print(f'ERROR: claude auth login failed with exit code {proc.returncode}')
        sys.exit(1)

    print('  ✓ Authentication complete')

asyncio.run(main())
"
        if ! claude auth status > /dev/null 2>&1; then
            echo "ERROR: Authentication failed"
            exit 1
        fi
        echo "✓ Claude Code: authenticated"
    fi
else
    echo "✓ CLI tool: ${CLI_TOOL} (API key auth, no interactive login needed)"
fi

# ── 2. SSH keys ──
mkdir -p ~/.ssh
ssh-keyscan github.com gitlab.com >> ~/.ssh/known_hosts 2>/dev/null || true

if [ -d /keys ] && [ "$(ls -A /keys 2>/dev/null)" ]; then
    for key in /keys/*; do
        chmod 600 "$key" 2>/dev/null
    done
    eval "$(ssh-agent -s)"
    ssh-add /keys/* 2>/dev/null || true
    echo "✓ SSH keys loaded"
else
    echo "– No SSH keys mounted"
fi

# ── 3. Clone or pull repositories ──
if [ -n "$GIT_REPOS" ] && [ "$GIT_REPOS" != "[]" ]; then
    echo "$GIT_REPOS" | python3 -c "
import json, sys, subprocess, os
for repo in json.load(sys.stdin):
    path = repo['localPath']
    url  = repo['cloneUrl']
    branch = repo.get('branch', 'main')
    if os.path.exists(os.path.join(path, '.git')):
        print(f'  pulling {path}')
        subprocess.run(['git', '-C', path, 'pull', '--ff-only'], check=False)
    else:
        print(f'  cloning {url} → {path}')
        os.makedirs(path, exist_ok=True)
        subprocess.run(['git', 'clone', '-b', branch, url, path], check=True)
"
    echo "✓ Repositories ready"
else
    echo "– No repositories configured"
fi

# ── 4. Configure MCP server ──
# Write .env for the MCP server
cat > /opt/aura/mcp-server/.env <<EOF
AURA_URL=$AURA_URL
AURA_API_KEY=$AURA_API_KEY
EOF

if [ "${CLI_TOOL:-claude}" = "claude" ]; then
    claude mcp add --scope user aura -- python3 /opt/aura/mcp-server/server.py
    echo "✓ MCP server registered"
fi

# ── 5. Generate configuration files ──
# Write .env for the SignalR client
cat > /opt/aura/signalr-client/.env <<EOF
KANBAN_URL=$AURA_URL
API_KEY=$AURA_API_KEY
PORT=${SIGNALR_CLIENT_PORT:-9002}
EOF

# Generate subscription.json from env vars
python3 /opt/aura/generate-subscription.py
echo "✓ Subscription config generated"

# Generate cli_tools.json
python3 -c "
import json
config = {
    'defaultTool': '${CLI_TOOL:-claude}',
    'userMappings': {}
}
model = '${CLI_MODEL:-}'
if model:
    config['defaultModel'] = model
with open('/opt/aura/signalr-client/cli_tools.json', 'w') as f:
    json.dump(config, f, indent=2)
"
echo "✓ CLI tools config generated"

# ── 6. Start SignalR client ──
echo "── Starting SignalR client ──"
cd /opt/aura/signalr-client
exec python3 signalr_receiver.py
