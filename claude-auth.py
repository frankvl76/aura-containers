"""
Claude Code authentication helper for Aura Containers.

Uses a PTY to interact with `claude auth login` (which requires a TTY).
Captures the OAuth URL, posts it to Aura, polls for the code, feeds it back.
"""

import os
import sys
import pty
import select
import json
import time
import urllib.request


AURA_URL = os.environ.get("AURA_URL", "").rstrip("/")
AURA_API_KEY = os.environ.get("AURA_API_KEY", "")
CONTAINER_ID = os.environ.get("CONTAINER_ID", "")


def aura_post(path, data):
    req = urllib.request.Request(
        f"{AURA_URL}{path}",
        data=json.dumps(data).encode(),
        headers={
            "Authorization": f"Bearer {AURA_API_KEY}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f"  warning: POST {path} failed: {e}", flush=True)


def aura_get(path):
    req = urllib.request.Request(
        f"{AURA_URL}{path}",
        headers={"Authorization": f"Bearer {AURA_API_KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except Exception as e:
        print(f"  warning: GET {path} failed: {e}", flush=True)
        return {}


def main():
    # Create a PTY pair
    master_fd, slave_fd = pty.openpty()

    pid = os.fork()

    if pid == 0:
        # Child: run claude auth login with the PTY as stdin/stdout/stderr
        os.close(master_fd)
        os.setsid()

        # Set slave as controlling terminal
        import fcntl
        import termios

        fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)

        os.dup2(slave_fd, 0)  # stdin
        os.dup2(slave_fd, 1)  # stdout
        os.dup2(slave_fd, 2)  # stderr
        if slave_fd > 2:
            os.close(slave_fd)

        os.execvp("claude", ["claude", "auth", "login"])
        # Never returns

    # Parent: interact with the child via master_fd
    os.close(slave_fd)

    login_url = None
    output_buffer = ""

    print("  Waiting for OAuth URL...", flush=True)

    # Read output until we find the URL
    deadline = time.time() + 60  # 60 second timeout
    while time.time() < deadline:
        ready, _, _ = select.select([master_fd], [], [], 1.0)
        if ready:
            try:
                data = os.read(master_fd, 4096).decode("utf-8", errors="replace")
                output_buffer += data

                # Process complete lines
                while "\n" in output_buffer:
                    line, output_buffer = output_buffer.split("\n", 1)
                    line = line.strip()
                    if line:
                        print(f"  [claude] {line}", flush=True)
                    if "http" in line:
                        for word in line.split():
                            if word.startswith("http"):
                                login_url = word
            except OSError:
                break

        if login_url:
            break

    # Check remaining buffer for URL
    if not login_url and output_buffer.strip():
        for word in output_buffer.split():
            if word.startswith("http"):
                login_url = word

    if not login_url:
        print("ERROR: Could not capture OAuth URL", flush=True)
        os.close(master_fd)
        os.waitpid(pid, 0)
        sys.exit(1)

    # Post URL to Aura
    print(f"  Auth URL captured, posting to Aura...", flush=True)
    aura_post(f"/api/containers/{CONTAINER_ID}/auth-url", {"url": login_url})

    # Poll Aura for the auth code
    print(f"  Waiting for auth code from Aura UI...", flush=True)
    code = None
    poll_deadline = time.time() + 600  # 10 minute timeout
    while code is None and time.time() < poll_deadline:
        time.sleep(2)
        result = aura_get(f"/api/containers/{CONTAINER_ID}/auth-code")
        code = (
            result.get("authCode")
            or result.get("code")
            or result.get("Code")
            or result.get("AuthCode")
        )

        # Drain any output from claude while waiting
        ready, _, _ = select.select([master_fd], [], [], 0.1)
        if ready:
            try:
                data = os.read(master_fd, 4096).decode("utf-8", errors="replace")
                if data.strip():
                    print(f"  [claude] {data.strip()}", flush=True)
            except OSError:
                pass

    if code is None:
        print("ERROR: Timed out waiting for auth code", flush=True)
        os.close(master_fd)
        os.waitpid(pid, 0)
        sys.exit(1)

    # Feed the code to claude via the PTY
    print(f"  Code received, submitting to Claude Code...", flush=True)
    os.write(master_fd, (code + "\n").encode())

    # Wait for claude to process and exit
    finish_deadline = time.time() + 30
    while time.time() < finish_deadline:
        ready, _, _ = select.select([master_fd], [], [], 1.0)
        if ready:
            try:
                data = os.read(master_fd, 4096).decode("utf-8", errors="replace")
                if data.strip():
                    print(f"  [claude] {data.strip()}", flush=True)
            except OSError:
                break

        # Check if child exited
        result = os.waitpid(pid, os.WNOHANG)
        if result[0] != 0:
            exit_code = os.WEXITSTATUS(result[1]) if os.WIFEXITED(result[1]) else 1
            print(f"  claude auth login exited with code {exit_code}", flush=True)
            os.close(master_fd)
            sys.exit(exit_code)

    # Timeout — kill child
    os.kill(pid, 9)
    os.waitpid(pid, 0)
    os.close(master_fd)
    print("ERROR: claude auth login didn't complete in time", flush=True)
    sys.exit(1)


if __name__ == "__main__":
    main()
