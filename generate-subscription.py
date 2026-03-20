"""Generate subscription.json for the SignalR client from environment variables.

Environment variables:
    SUBSCRIPTION_PROJECTS   - Comma-separated project GUIDs (required)
    SUBSCRIPTION_USER_IDS   - Comma-separated user GUIDs to filter (optional)
    SUBSCRIPTION_EVENTS     - Event bitmask (default: 19 = Created+StatusChanged+AssignmentChanged)
    SUBSCRIPTION_STATUSES   - Comma-separated statuses to filter on (default: "Todo")
    AURA_URL                - Aura server URL (used to look up current user if SUBSCRIPTION_USER_IDS not set)
    AURA_API_KEY            - Aura API key (used to look up current user)
"""

import json
import os
import urllib.request

OUTPUT_PATH = "/opt/aura/signalr-client/subscription.json"

# ── Event bitmask ──
# TicketCreated=1, TicketStatusChanged=2, TicketUpdated=4,
# CommentAdded=8, TicketAssignmentChanged=16
DEFAULT_EVENTS = 19  # Created + StatusChanged + AssignmentChanged


def get_current_user_id():
    """Look up the current user ID from the API key."""
    aura_url = os.environ.get("AURA_URL", "").rstrip("/")
    api_key = os.environ.get("AURA_API_KEY", "")
    if not aura_url or not api_key:
        return None

    url = f"{aura_url}/api/auth/me"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {api_key}",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            return data.get("id")
    except Exception as e:
        print(f"  warning: could not look up current user: {e}")
        return None


def main():
    # Parse project IDs
    projects_raw = os.environ.get("SUBSCRIPTION_PROJECTS", "")
    project_ids = [p.strip() for p in projects_raw.split(",") if p.strip()]

    # Parse user IDs (or look up from API key)
    users_raw = os.environ.get("SUBSCRIPTION_USER_IDS", "")
    user_ids = [u.strip() for u in users_raw.split(",") if u.strip()]

    if not user_ids:
        current_user = get_current_user_id()
        if current_user:
            user_ids = [current_user]
            print(f"  resolved current user: {current_user}")

    # Parse events bitmask
    events = int(os.environ.get("SUBSCRIPTION_EVENTS", str(DEFAULT_EVENTS)))

    # Parse status filters
    statuses_raw = os.environ.get("SUBSCRIPTION_STATUSES", "Todo")
    statuses = [s.strip() for s in statuses_raw.split(",") if s.strip()]

    # Build status filters for relevant event types
    status_filters = {}
    if statuses:
        if events & 1:   # TicketCreated
            status_filters["TicketCreated"] = statuses
        if events & 2:   # TicketStatusChanged
            status_filters["TicketStatusChanged"] = statuses
        if events & 16:  # TicketAssignmentChanged
            status_filters["TicketAssignmentChanged"] = statuses

    # Build subscription config
    subscription = {
        "events": events,
        "allProjects": len(project_ids) == 0,
        "allUsers": len(user_ids) == 0,
    }

    if project_ids:
        subscription["projectIds"] = project_ids

    if user_ids:
        subscription["userIds"] = user_ids

    if status_filters:
        subscription["statusFilters"] = status_filters

    # Write output
    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, "w") as f:
        json.dump(subscription, f, indent=2)

    print(f"  wrote {OUTPUT_PATH}")
    print(f"  projects: {len(project_ids)}, users: {len(user_ids)}, events: {events}")


if __name__ == "__main__":
    main()
