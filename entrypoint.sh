#!/bin/bash
set -e

echo "── Aura Agent starting ──"

# ── 1. Start ttyd web terminal (background) ──
TTYD_USER="${TTYD_USER:-admin}"
TTYD_PASS="${TTYD_PASS:-admin}"
ttyd -W -p 7681 -c "${TTYD_USER}:${TTYD_PASS}" /bin/bash &
echo "✓ Web terminal running on port 7681"

# ── 2. Authentication ──
if [ "${CLI_TOOL:-claude}" = "claude" ]; then
    if claude auth status > /dev/null 2>&1; then
        echo "✓ Claude Code: authenticated"
    else
        echo "⏳ Claude Code: not authenticated"
        echo "   Use the web terminal to run: claude auth login"

        # Report awaiting-auth status to Aura
        curl -s -X POST "$AURA_URL/api/containers/$CONTAINER_ID/heartbeat" \
          -H "Authorization: Bearer $AURA_API_KEY" \
          -H "Content-Type: application/json" \
          -d '{"awaitingAuth": true}' || true

        # Wait until authenticated (admin will auth via ttyd)
        while ! claude auth status > /dev/null 2>&1; do
            sleep 5
        done
        echo "✓ Claude Code: authenticated"
    fi
else
    echo "✓ CLI tool: ${CLI_TOOL} (API key auth, no interactive login needed)"
fi

# ── 3. SSH keys ──
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

# ── 4. Clone or pull repositories ──
if [ -n "$GIT_REPOS" ] && [ "$GIT_REPOS" != "[]" ]; then
    echo "$GIT_REPOS" | python3 -u -c "
import json, sys, subprocess, os, re
for repo in json.load(sys.stdin):
    path = repo['localPath']
    url  = repo['cloneUrl']
    branch = repo.get('branch', 'main')
    token = repo.get('accessToken')

    # If we have an access token and the URL is SSH, convert to HTTPS
    if token and url.startswith('git@'):
        # git@github.com:org/repo.git -> https://x-access-token:{token}@github.com/org/repo.git
        match = re.match(r'git@([^:]+):(.+)', url)
        if match:
            url = f'https://x-access-token:{token}@{match.group(1)}/{match.group(2)}'
    elif token and url.startswith('https://'):
        # Insert token into HTTPS URL
        url = url.replace('https://', f'https://x-access-token:{token}@')

    if os.path.exists(os.path.join(path, '.git')):
        print(f'  pulling {path}', flush=True)
        subprocess.run(['git', '-C', path, 'pull', '--ff-only'], check=False)
    else:
        # Don't print token in logs
        display_url = re.sub(r'://[^@]+@', '://***@', url) if token else url
        print(f'  cloning {display_url} -> {path}', flush=True)
        os.makedirs(path, exist_ok=True)
        subprocess.run(['git', 'clone', '-b', branch, url, path], check=True)
"
    echo "✓ Repositories ready"
else
    echo "– No repositories configured"
fi

# ── 5. Configure MCP server ──
cat > /opt/aura/mcp-server/.env <<EOF
AURA_URL=$AURA_URL
AURA_API_KEY=$AURA_API_KEY
EOF

if [ "${CLI_TOOL:-claude}" = "claude" ]; then
    claude mcp add --scope user aura -- python3 /opt/aura/mcp-server/server.py
    echo "✓ MCP server registered"
fi

# ── 6. Generate configuration files ──
cat > /opt/aura/signalr-client/.env <<EOF
KANBAN_URL=$AURA_URL
API_KEY=$AURA_API_KEY
PORT=${SIGNALR_CLIENT_PORT:-9002}
EOF

python3 /opt/aura/generate-subscription.py
echo "✓ Subscription config generated"

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

# ── 7. Start SignalR client ──
echo "── Starting SignalR client ──"
cd /opt/aura/signalr-client
exec python3 signalr_receiver.py
