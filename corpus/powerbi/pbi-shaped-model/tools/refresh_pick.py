"""Dependency-free choice of 'this run's' dataset refresh from a refresh-history listing.

Shared by fabric_publish.py (polling) and verify_pbi.py (check a), so a stale earlier "Completed"
is never mistaken for the refresh this run requested.
"""
import datetime

# Server and local clocks can differ. The tolerance applies ONLY on the startTime fallback (no RequestId
# match), where a refresh we started could be stamped slightly before our local request time.
SKEW_SECONDS = 5
_FMT = "%Y-%m-%dT%H:%M:%S"


def _parse(ts):
    return datetime.datetime.strptime(ts[:19], _FMT)


def pick_refresh(entries, since=None, request_id=None):
    """Newest refresh entry belonging to this run, or {} when it is not listed yet.

    1. an entry whose requestId equals request_id;
    2. else, with `since` (ISO UTC, the local time just before the request), the newest entry whose
       startTime >= since - SKEW_SECONDS;
    3. with neither, the newest entry (plain 'latest refresh' semantics).
    `entries` are newest first, as the API lists them."""
    if request_id:
        for e in entries:
            if e.get("requestId") == request_id:
                return e
    if since:
        floor = _parse(since) - datetime.timedelta(seconds=SKEW_SECONDS)
        for e in entries:
            if e.get("startTime") and _parse(e["startTime"]) >= floor:
                return e
        return {}
    return {} if request_id else (entries[0] if entries else {})
