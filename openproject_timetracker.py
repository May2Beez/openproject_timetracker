#!/usr/bin/env python3
"""
OpenProject Time Tracker - Console App
Scans your time entries, lists unfilled days, and lets you log hours.
Supports favorite work packages (stored in ~/.openproject_favorites.json).
Activity is hardcoded to ID=1 / "Management".
"""

import os
import sys
import json
import requests
from datetime import date, timedelta
from collections import defaultdict
from typing import Optional
from pathlib import Path
from dotenv import load_dotenv

import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


# ── Hardcoded activity ────────────────────────────────────────────────────────

ACTIVITY_ID   = 1
ACTIVITY_NAME = "Management"


# ── Favorites storage ─────────────────────────────────────────────────────────

FAVORITES_FILE = Path.home() / ".openproject_favorites.json"


def load_favorites() -> list[dict]:
    if not FAVORITES_FILE.exists():
        return []
    try:
        return json.loads(FAVORITES_FILE.read_text())
    except Exception:
        return []


def save_favorites(favorites: list[dict]):
    FAVORITES_FILE.write_text(json.dumps(favorites, indent=2))


def add_favorite(wp: dict) -> bool:
    """Add WP to favorites. Returns False if already present."""
    favorites = load_favorites()
    if any(f["id"] == wp["id"] for f in favorites):
        return False
    favorites.append({
        "id":      wp["id"],
        "subject": wp.get("subject", "?"),
        "project": wp.get("_embedded", {}).get("project", {}).get("name", "?"),
    })
    save_favorites(favorites)
    return True


def remove_favorite(wp_id: int) -> bool:
    """Remove WP from favorites by ID. Returns True if something was removed."""
    favorites = load_favorites()
    new = [f for f in favorites if f["id"] != wp_id]
    save_favorites(new)
    return len(new) < len(favorites)


# ── Configuration ─────────────────────────────────────────────────────────────

def get_config() -> tuple[str, str, bool]:
    load_dotenv()
    url        = os.environ.get("OPENPROJECT_URL", "").rstrip("/")
    token      = os.environ.get("OPENPROJECT_TOKEN", "")
    verify_ssl = False

    if not url:
        url   = input("OpenProject URL (e.g. https://your-instance.openproject.com): ").strip().rstrip("/")
    if not token:
        token = input("Your API token: ").strip()

    return url, token, verify_ssl


# ── API helpers ───────────────────────────────────────────────────────────────

class OpenProjectAPI:
    def __init__(self, base_url: str, token: str, verify_ssl: bool = True):
        self.base = base_url
        self.session = requests.Session()
        self.session.auth = ("apikey", token)
        self.session.headers.update({"Content-Type": "application/json"})
        self.session.verify = verify_ssl

    def _get(self, path: str, params: dict = None) -> dict:
        r = self.session.get(f"{self.base}/api/v3{path}", params=params)
        r.raise_for_status()
        return r.json()

    def _post(self, path: str, payload: dict) -> dict:
        r = self.session.post(f"{self.base}/api/v3{path}", json=payload)
        r.raise_for_status()
        return r.json()

    def get_current_user(self) -> dict:
        return self._get("/users/me")

    def get_time_entries(self, user_id: int, from_date: date, to_date: date) -> list[dict]:
        entries, offset, page_size = [], 1, 100
        while True:
            data = self._get("/time_entries", params={
                "filters": json.dumps([
                    {"user_id":  {"operator": "=",   "values": [str(user_id)]}},
                    {"spent_on": {"operator": "<>d", "values": [
                        from_date.isoformat(), to_date.isoformat()
                    ]}},
                ]),
                "offset": offset, "pageSize": page_size,
            })
            elements = data.get("_embedded", {}).get("elements", [])
            entries.extend(elements)
            if offset * page_size >= data.get("total", 0):
                break
            offset += 1
        return entries

    def search_work_packages(self, query: str) -> list[dict]:
        data = self._get("/work_packages", params={
            "filters": json.dumps([
                {"subject": {"operator": "~", "values": [query]}}
            ]),
            "pageSize": 20,
        })
        return data.get("_embedded", {}).get("elements", [])

    def get_work_package(self, wp_id: int) -> dict:
        return self._get(f"/work_packages/{wp_id}")

    def log_time(self, wp_id: int, spent_on: date, hours: float, comment: str = "") -> dict:
        payload = {
            "_links": {
                "workPackage": {"href": f"/api/v3/work_packages/{wp_id}"},
                "activity":    {"href": f"/api/v3/time_entries/activities/{ACTIVITY_ID}"},
            },
            "hours":   f"PT{hours}H",
            "spentOn": spent_on.isoformat(),
            "comment": {"raw": comment},
        }
        return self._post("/time_entries", payload)


# ── Time-entry analysis ───────────────────────────────────────────────────────

def parse_hours(iso_duration: str) -> float:
    iso_duration = iso_duration.upper().lstrip("P")
    hours = minutes = 0.0
    if "T" in iso_duration:
        iso_duration = iso_duration.split("T")[1]
    if "H" in iso_duration:
        parts        = iso_duration.split("H")
        hours        = float(parts[0])
        iso_duration = parts[1]
    if "M" in iso_duration:
        minutes = float(iso_duration.replace("M", ""))
    return hours + minutes / 60


def group_by_day(entries: list[dict]) -> dict[str, list[dict]]:
    grouped = defaultdict(list)
    for e in entries:
        grouped[e.get("spentOn", "unknown")].append(e)
    return dict(grouped)


def unfilled_days(
    grouped: dict[str, list[dict]],
    from_date: date,
    to_date: date,
    min_hours: float = 8.0,
    skip_weekends: bool = True,
) -> list[tuple[date, list[dict], float]]:
    result, current = [], from_date
    while current <= to_date:
        if skip_weekends and current.weekday() >= 5:
            current += timedelta(days=1)
            continue
        day_str     = current.isoformat()
        day_entries = grouped.get(day_str, [])
        total       = sum(parse_hours(e.get("hours", "PT0H")) for e in day_entries)
        if total < min_hours:
            result.append((current, day_entries, total))
        current += timedelta(days=1)
    return result


# ── Display helpers ───────────────────────────────────────────────────────────

RESET  = "\033[0m"
BOLD   = "\033[1m"
CYAN   = "\033[96m"
YELLOW = "\033[93m"
GREEN  = "\033[92m"
RED    = "\033[91m"
DIM    = "\033[2m"
GOLD   = "\033[33m"


def fmt_hours(h: float) -> str:
    return f"{h:.1f}h"


def entry_label(e: dict) -> str:
    subject = (
        e.get("_embedded", {}).get("workPackage", {}).get("subject")
        or e.get("comment", {}).get("raw", "")
        or "—"
    )
    return f"{subject} ({fmt_hours(parse_hours(e.get('hours', 'PT0H')))})"


def print_header(text: str):
    print(f"\n{BOLD}{CYAN}{'─' * 60}{RESET}")
    print(f"{BOLD}{CYAN}  {text}{RESET}")
    print(f"{BOLD}{CYAN}{'─' * 60}{RESET}\n")


def print_unfilled_days(days: list[tuple[date, list[dict], float]]):
    if not days:
        print(f"{GREEN}  ✓ All days are filled!{RESET}\n")
        return
    for i, (d, entries, total) in enumerate(days, 1):
        bar_filled = int(total / 8 * 20)
        bar        = f"{'█' * bar_filled}{'░' * (20 - bar_filled)}"
        color      = RED if total == 0 else YELLOW
        print(f"  {BOLD}[{i:>2}]{RESET}  {d.strftime('%d-%b-%Y')}  {color}{bar} {fmt_hours(total)}/8h{RESET}")
        if entries:
            for e in entries:
                print(f"         {DIM}• {entry_label(e)}{RESET}")
        else:
            print(f"         {DIM}(no entries){RESET}")
    print()


def print_favorites_list(favorites: list[dict]):
    if not favorites:
        print(f"  {DIM}(no favorites saved yet){RESET}\n")
        return
    for i, f in enumerate(favorites, 1):
        print(f"  {GOLD}★{RESET} {BOLD}[{i:>2}]{RESET}  #{f['id']}  {f['subject']}  {DIM}({f['project']}){RESET}")
    print()


# ── Work-package pickers ──────────────────────────────────────────────────────

def _search_wp(api: OpenProjectAPI) -> Optional[dict]:
    query = input("Search keyword: ").strip()
    if not query:
        return None
    print(f"\n{DIM}Searching…{RESET}")
    wps = api.search_work_packages(query)
    if not wps:
        print(f"{RED}No work packages found.{RESET}")
        return None
    print()
    for i, wp in enumerate(wps, 1):
        project = wp.get("_embedded", {}).get("project", {}).get("name", "?")
        print(f"  {BOLD}[{i:>2}]{RESET}  #{wp['id']}  {wp['subject']}  {DIM}({project}){RESET}")
    print()
    while True:
        raw = input(f"Select (1-{len(wps)}) or {BOLD}q{RESET}: ").strip()
        if raw.lower() == "q":
            return None
        if raw.isdigit() and 1 <= int(raw) <= len(wps):
            return wps[int(raw) - 1]
        print(f"{RED}Invalid.{RESET}")


def _wp_by_id(api: OpenProjectAPI) -> Optional[dict]:
    raw = input("Work Package ID: ").strip()
    if not raw.isdigit():
        print(f"{RED}Not a valid ID.{RESET}")
        return None
    try:
        return api.get_work_package(int(raw))
    except requests.HTTPError as e:
        print(f"{RED}Error fetching WP: {e}{RESET}")
        return None


def _pick_from_favorites(api: OpenProjectAPI) -> Optional[dict]:
    favorites = load_favorites()
    print()
    print_favorites_list(favorites)
    while True:
        raw = input(f"Select favorite (1-{len(favorites)}) or {BOLD}q{RESET}: ").strip()
        if raw.lower() == "q":
            return None
        if raw.isdigit() and 1 <= int(raw) <= len(favorites):
            fav = favorites[int(raw) - 1]
            try:
                return api.get_work_package(fav["id"])
            except requests.HTTPError as e:
                print(f"{RED}Error fetching WP #{fav['id']}: {e}{RESET}")
                return None
        print(f"{RED}Invalid.{RESET}")


def pick_work_package(api: OpenProjectAPI) -> Optional[dict]:
    """Full WP picker with favorites / search / ID options."""
    favorites = load_favorites()

    print_header("Select a Work Package")

    if favorites:
        print(f"  {BOLD}[f]{RESET}  {GOLD}★{RESET}  Pick from favorites  {DIM}({len(favorites)} saved){RESET}")
    print(f"  {BOLD}[s]{RESET}     Search by keyword")
    print(f"  {BOLD}[i]{RESET}     Enter Work Package ID directly")
    print(f"  {BOLD}[q]{RESET}     Cancel\n")

    valid = {"s", "i", "q"} | ({"f"} if favorites else set())
    while True:
        choice = input("Choice: ").strip().lower()
        if choice in valid:
            break
        print(f"{RED}Invalid.{RESET}")

    if choice == "q":
        return None
    if choice == "f":
        return _pick_from_favorites(api)
    if choice == "s":
        return _search_wp(api)
    if choice == "i":
        return _wp_by_id(api)
    return None


# ── Favorites management screen ───────────────────────────────────────────────

def manage_favorites(api: OpenProjectAPI):
    while True:
        print_header(f"{GOLD}★{RESET}  Manage Favorite Work Packages")
        favorites = load_favorites()
        print_favorites_list(favorites)

        print(f"  {BOLD}[a]{RESET}  Add a favorite")
        if favorites:
            print(f"  {BOLD}[r]{RESET}  Remove a favorite")
        print(f"  {BOLD}[b]{RESET}  Back\n")

        choice = input("Choice: ").strip().lower()

        if choice == "b":
            break

        elif choice == "a":
            print_header("Add to Favorites – Find a Work Package")
            print(f"  {BOLD}[s]{RESET}  Search by keyword")
            print(f"  {BOLD}[i]{RESET}  Enter Work Package ID directly")
            print(f"  {BOLD}[q]{RESET}  Cancel\n")
            sub = input("Choice: ").strip().lower()
            wp = None
            if sub == "s":
                wp = _search_wp(api)
            elif sub == "i":
                wp = _wp_by_id(api)
            if wp:
                if add_favorite(wp):
                    print(f"\n{GREEN}✓ Added #{wp['id']} \"{wp['subject']}\" to favorites.{RESET}\n")
                else:
                    print(f"\n{YELLOW}Already in favorites.{RESET}\n")

        elif choice == "r" and favorites:
            while True:
                raw = input(f"Remove number (1-{len(favorites)}) or {BOLD}q{RESET}: ").strip()
                if raw.lower() == "q":
                    break
                if raw.isdigit() and 1 <= int(raw) <= len(favorites):
                    f = favorites[int(raw) - 1]
                    remove_favorite(f["id"])
                    print(f"\n{GREEN}✓ Removed #{f['id']} \"{f['subject']}\" from favorites.{RESET}\n")
                    break
                print(f"{RED}Invalid.{RESET}")

        else:
            print(f"{RED}Invalid.{RESET}")


# ── Log hours flow ────────────────────────────────────────────────────────────

def log_hours_flow(api: OpenProjectAPI, day: date, existing_total: float):
    wp = pick_work_package(api)
    if not wp:
        return

    remaining = max(0.0, 8.0 - existing_total)

    print(f"\n  Work Package   : {BOLD}#{wp['id']} {wp['subject']}{RESET}")
    print(f"  Activity       : {BOLD}{ACTIVITY_NAME}{RESET}  {DIM}(id {ACTIVITY_ID}){RESET}")
    print(f"  Date           : {BOLD}{day.strftime('%d-%b-%Y')}{RESET}")
    print(f"  Already logged : {fmt_hours(existing_total)}  |  Remaining to 8h: {fmt_hours(remaining)}\n")

    while True:
        raw = input(f"Hours to log (e.g. 3.5) [{fmt_hours(remaining)} suggested]: ").strip()
        if not raw:
            hours = remaining
            break
        try:
            hours = float(raw)
            if hours > 0:
                break
            print(f"{RED}Must be positive.{RESET}")
        except ValueError:
            print(f"{RED}Enter a number.{RESET}")

    comment = input("Comment (optional): ").strip()

    # Offer to save as favorite (only if not already saved)
    favorites = load_favorites()
    if not any(f["id"] == wp["id"] for f in favorites):
        if input(f"Add #{wp['id']} to favorites? (y/N): ").strip().lower() == "y":
            add_favorite(wp)
            print(f"{GREEN}✓ Saved to favorites.{RESET}")

    print(f"\n{DIM}Logging {fmt_hours(hours)} to #{wp['id']}…{RESET}")
    try:
        result = api.log_time(
            wp_id=wp["id"],
            spent_on=day,
            hours=hours,
            comment=comment,
        )
        print(f"{GREEN}✓ Time entry created (ID {result.get('id', '?')}){RESET}\n")
    except requests.HTTPError as e:
        print(f"{RED}Failed to log time: {e}{RESET}\n")
        try:
            print(e.response.text)
        except Exception:
            pass


# ── Day picker ────────────────────────────────────────────────────────────────

def pick_day(days: list[tuple[date, list[dict], float]]) -> Optional[tuple[date, list[dict], float]]:
    print_header("Select an unfilled day")
    print_unfilled_days(days)
    while True:
        raw = input(
            f"Day number (1-{len(days)}), "
            f"{BOLD}f{RESET} = manage favorites, "
            f"{BOLD}q{RESET} = quit: "
        ).strip()
        if raw.lower() == "q":
            return None
        if raw.lower() == "f":
            return "favorites"  # sentinel value
        if raw.isdigit() and 1 <= int(raw) <= len(days):
            return days[int(raw) - 1]
        print(f"{RED}Invalid choice.{RESET}")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    print(f"\n{BOLD}OpenProject Time Tracker{RESET}")
    print(f"{DIM}─────────────────────────────────────────────────{RESET}\n")

    try:
        base_url, token, verify_ssl = get_config()
    except KeyboardInterrupt:
        sys.exit(0)

    if not verify_ssl:
        print(f"{YELLOW}⚠ SSL verification disabled.{RESET}")
    else:
        if os.environ.get("OPENPROJECT_VERIFY_SSL") is None:
            if input("Disable SSL certificate verification? (y/N): ").strip().lower() == "y":
                verify_ssl = False
                print(f"{YELLOW}⚠ SSL verification disabled.{RESET}")

    api = OpenProjectAPI(base_url, token, verify_ssl=verify_ssl)

    print(f"\n{DIM}Connecting…{RESET}")
    try:
        me = api.get_current_user()
    except requests.HTTPError as e:
        print(f"{RED}Authentication failed: {e}{RESET}")
        sys.exit(1)

    name = me.get("name") or me.get("login", "Unknown")
    print(f"{GREEN}✓ Logged in as {BOLD}{name}{RESET}")
    print(f"  Activity hardcoded: {BOLD}{ACTIVITY_NAME}{RESET} {DIM}(id {ACTIVITY_ID}){RESET}\n")

    # ── Date range ────────────────────────────────────────────────────────────
    today        = date.today()
    default_from = today.replace(day=1)
    print(f"  Scanning from {BOLD}{default_from}{RESET} to {BOLD}{today}{RESET}")
    if input("  Use a different range? (y/N): ").strip().lower() == "y":
        try:
            from_date = date.fromisoformat(input("  From (YYYY-MM-DD): ").strip())
            to_date   = date.fromisoformat(input("  To   (YYYY-MM-DD): ").strip())
        except ValueError:
            print(f"{RED}Invalid date format.{RESET}")
            sys.exit(1)
    else:
        from_date, to_date = default_from, today

    skip_weekends = input("  Skip weekends? (Y/n): ").strip().lower() != "n"

    # ── Fetch entries ─────────────────────────────────────────────────────────
    print(f"\n{DIM}Fetching time entries…{RESET}")
    try:
        entries = api.get_time_entries(me["id"], from_date, to_date)
    except requests.HTTPError as e:
        print(f"{RED}Error fetching entries: {e}{RESET}")
        sys.exit(1)

    grouped  = group_by_day(entries)
    unfilled = unfilled_days(grouped, from_date, to_date, skip_weekends=skip_weekends)

    print(f"  Found {len(entries)} entries across {len(grouped)} days.")
    print(f"  {YELLOW}{len(unfilled)} day(s) below 8h threshold.{RESET}\n")

    if not unfilled:
        print(f"{GREEN}Great — no unfilled days in this period!{RESET}\n")
        if input("Manage favorites? (y/N): ").strip().lower() == "y":
            manage_favorites(api)
        return

    # ── Main interaction loop ─────────────────────────────────────────────────
    while True:
        selected = pick_day(unfilled)

        if selected is None:
            break

        if selected == "favorites":
            manage_favorites(api)
            continue

        day, day_entries, total = selected
        print(f"\n  Selected: {BOLD}{day.strftime('%d-%b-%Y')}{RESET}  ({fmt_hours(total)} logged)\n")

        log_hours_flow(api, day, total)

        # Refresh
        print(f"{DIM}Refreshing entries…{RESET}")
        try:
            entries  = api.get_time_entries(me["id"], from_date, to_date)
            grouped  = group_by_day(entries)
            unfilled = unfilled_days(grouped, from_date, to_date, skip_weekends=skip_weekends)
        except requests.HTTPError:
            pass

        if not unfilled:
            print(f"\n{GREEN}🎉 All days are now filled!{RESET}\n")
            break

        if input("Log more hours? (Y/n): ").strip().lower() == "n":
            break

    print(f"\n{DIM}Bye!{RESET}\n")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"\n{DIM}Interrupted.{RESET}\n")
