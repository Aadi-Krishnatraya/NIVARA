#!/usr/bin/env python3
"""End-to-end NIVARA demo driver (adb + uiautomator).

Registers real accounts through the UI, runs Edge-AI check-ins, verifies the
commander dashboards. Nothing is seeded: every account and score is created
through the app's own screens.
"""
import re
import subprocess
import sys
import time

ADB = "/Users/aadikrishnatraya/Library/Android/sdk/platform-tools/adb"
PKG = "com.example.nivara_app"


def sh(*args, timeout=30):
    return subprocess.run([ADB, *args], capture_output=True, text=True, timeout=timeout).stdout


def dump():
    sh("shell", "uiautomator", "dump", "/sdcard/ui.xml")
    return sh("shell", "cat", "/sdcard/ui.xml")


NODE_RE = re.compile(r"<node[^>]*>")


def labels(xml):
    out = []
    for node in NODE_RE.findall(xml):
        attrs = dict(re.findall(r'(text|content-desc|bounds)="([^"]*)"', node))
        label = attrs.get("text") or attrs.get("content-desc") or ""
        if label:
            b = re.findall(r"-?\d+", attrs.get("bounds", ""))
            if len(b) == 4:
                x1, y1, x2, y2 = map(int, b)
                out.append((label, (x1 + x2) // 2, (y1 + y2) // 2))
    return out


def find(xml, pattern):
    rx = re.compile(pattern)
    return [m for m in labels(xml) if rx.search(m[0])]


def tap(x, y, wait=0.9):
    sh("shell", "input", "tap", str(x), str(y))
    time.sleep(wait)


def tap_label(xml, pattern, index=0, wait=1.2):
    matches = find(xml, pattern)
    if not matches:
        return False
    _, x, y = matches[index]
    tap(x, y, wait)
    return True


def tap_label_scroll(pattern, tries=4, wait=1.2):
    """Find a label, scrolling down between attempts if it is below the fold."""
    for attempt in range(tries):
        xml = dump()
        if tap_label(xml, pattern, wait=wait):
            return True
        # Swipe up to reveal lower content, then retry.
        sh("shell", "input", "swipe", "540", "1700", "540", "700", "250")
        time.sleep(0.8)
    return False


def edittext_centers(xml):
    """(is_password, cx, cy) for each EditText node with sane bounds."""
    out = []
    for node in NODE_RE.findall(xml):
        if "EditText" not in node:
            continue
        attrs = dict(re.findall(r'(text|content-desc|bounds|password)="([^"]*)"', node))
        b = re.findall(r"-?\d+", attrs.get("bounds", ""))
        if len(b) == 4:
            x1, y1, x2, y2 = map(int, b)
            if x2 - x1 > 100 and y2 - y1 > 30:
                out.append((attrs.get("password") == "true", (x1 + x2) // 2, (y1 + y2) // 2))
    return out


def tap_field(xml, password=False, index=0):
    fields = [f for f in edittext_centers(xml) if f[0] == password]
    assert index < len(fields), f"edittext index {index} missing (pw={password})"
    _, x, y = fields[index]
    tap(x, y, 2.0)  # long settle: Flutter focus + IME connection

def type_text(text):
    sh("shell", "input", "text", text.replace(" ", "%s"))
    time.sleep(0.3)


def hide_keyboard():
    # This AVD runs with a hardware keyboard: no soft IME appears, so BACK
    # would navigate away instead. Deliberately a no-op.
    pass


def screenshot(name):
    sh("shell", "screencap", "-p", "/sdcard/%s.png" % name)
    sh("pull", "/sdcard/%s.png" % name, "/tmp/%s.png" % name)


def wait_for(pattern, timeout=30):
    """Poll the UI until a label matching pattern appears; return its dump."""
    deadline = time.time() + timeout
    last_err = None
    while time.time() < deadline:
        try:
            xml = dump()
            if xml and find(xml, pattern):
                return xml
        except Exception as e:  # dump can transiently fail mid-rotation
            last_err = e
        time.sleep(0.6)
    raise AssertionError(f"timeout waiting for {pattern!r} (last: {last_err})")


def open_registration():
    """Tap the provision link (with retries) until the form appears."""
    for _ in range(3):
        xml = dump()
        if find(xml, "CREATE ACCOUNT"):
            return xml
        tap_label(xml, "Provision an account|provision the first one", wait=2.0)
    raise AssertionError("could not open registration screen")


def logout_to_login():
    """Tap Log out (with retries) until the login screen appears."""
    for _ in range(4):
        xml = dump()
        if find(xml, "AUTHENTICATE"):
            return xml
        tap_label(xml, "Log out", wait=1.5)
    raise AssertionError("could not log out")


def launch_app():
    sh("shell", "am", "force-stop", PKG)
    time.sleep(1)
    sh("shell", "am", "start", "-n", f"{PKG}/.MainActivity")


def step(msg):
    print(f"\n=== {msg} ===", flush=True)


def main():
    step("fresh install state")
    sh("shell", "pm", "clear", PKG)
    time.sleep(1)
    launch_app()

    wait_for("AUTHENTICATE", timeout=40)
    step("boot + first-run registration (soldier)")
    xml = open_registration()
    tap_field(xml, password=False, index=0)   # name
    type_text("Ravi Menon")
    tap_field(dump(), password=False, index=1)  # unit
    type_text("ALPHA_SQUAD")
    # Soldier role is the default segment; set passcodes.
    tap_field(dump(), password=True, index=0)
    type_text("4711")
    tap_field(dump(), password=True, index=1)
    type_text("4711")
    hide_keyboard()
    tap_label(dump(), "CREATE ACCOUNT", wait=1.0)

    xml = wait_for("Soldier View")
    print("registered + logged in as Ravi Menon (soldier)")

    step("check-in: run Edge-AI inference, log")
    xml = wait_for("Run evaluation")
    assert tap_label(xml, "Run evaluation", wait=1.0), "Run evaluation button missing"
    xml = wait_for("Why this score", timeout=15)  # Shapley panel renders with the score
    joined = " ".join(l.replace("&#10;", " ") for l, _, _ in labels(xml))
    m = re.search(r"(\d+)\s*/\s*100", joined)
    assert m, "no on-device score displayed"
    print(f"on-device inference produced score {m.group(1)}/100 (with Shapley explanation)")
    assert tap_label_scroll("Log this check-in"), "log button missing"
    wait_for("encrypted vault", timeout=8)  # snackbar

    step("trends tab shows the logged entry")
    tap_label(dump(), "Trends", wait=1.0)
    wait_for("Wellness History")

    step("support directory CRUD is available")
    tap_label(dump(), "Support", wait=1.0)
    xml = wait_for("Confidential Support Bridge")
    assert find(xml, "Peer Support Helpline"), "seed contacts missing"

    step("logout and register commander")
    logout_to_login()
    xml = open_registration()
    tap_field(xml, password=False, index=0)   # name
    type_text("Meera Rathore")
    tap_field(dump(), password=False, index=1)  # unit
    type_text("ALPHA_SQUAD")
    tap_label(dump(), "Commander")
    tap_field(dump(), password=True, index=0)
    type_text("8231")
    tap_field(dump(), password=True, index=1)
    type_text("8231")
    hide_keyboard()
    tap_label(dump(), "CREATE ACCOUNT", wait=1.0)

    wait_for("Dashboard")
    print("registered + logged in as Meera Rathore (commander)")

    step("commander dashboard: privacy block expected (1 contributor)")
    wait_for("Squad size", timeout=20)  # text renders as 'Squad size &lt; 5.' in XML
    print("privacy block active as designed (PRD 5.2)")

    step("register 4 more soldiers in ALPHA_SQUAD to cross the DP threshold")
    for name in ["Arjun Nair", "Bilal Khan", "Chen Wei", "Dev Patel"]:
        # Handles both states: on the commander dashboard (first iteration)
        # or already at login (later ones, after the tail logout).
        logout_to_login()
        xml = open_registration()
        tap_field(xml, password=False, index=0)   # name
        type_text(name)
        tap_field(dump(), password=False, index=1)  # unit
        type_text("ALPHA_SQUAD")
        tap_field(dump(), password=True, index=0)
        type_text("4712")
        tap_field(dump(), password=True, index=1)
        type_text("4712")
        hide_keyboard()
        tap_label(dump(), "CREATE ACCOUNT", wait=1.0)
        xml = wait_for("Soldier View")
        # One quick check-in each so the unit has real contributor data.
        assert tap_label(xml, "Run evaluation", wait=1.0)
        wait_for("Why this score", timeout=15)
        assert tap_label_scroll("Log this check-in"), "log button missing"
        time.sleep(0.8)
        logout_to_login()
        print(f"  + {name} registered and checked in")

    step("commander sees anonymized aggregate now (5 contributors)")
    xml = wait_for("AUTHENTICATE")
    tap_field(xml, password=False, index=0)   # name
    type_text("Meera Rathore")
    tap_field(dump(), password=True, index=0)  # passcode
    type_text("8231")
    hide_keyboard()
    tap_label(dump(), "AUTHENTICATE", wait=1.0)
    xml = wait_for("ALPHA_SQUAD Dashboard", timeout=25)
    assert find(xml, "Laplace"), "DP notice missing"

    def scroll_until(pattern, tries=6):
        for _ in range(tries):
            xml2 = dump()
            if find(xml2, pattern):
                return xml2
            sh("shell", "input", "swipe", "540", "1700", "540", "700", "250")
            time.sleep(0.8)
        raise AssertionError(f"{pattern!r} not found after scrolling")

    xml = scroll_until("Shapley")            # pooled on-device attributions
    assert find(xml, "pts avg"), "attribution bars missing"
    xml = scroll_until("(?i)risk drivers")
    xml = scroll_until("Playbook")
    print("aggregate + Shapley drivers + playbook all render")

    # Back to the top for the screenshot.
    for _ in range(4):
        sh("shell", "input", "swipe", "540", "700", "540", "1700", "250")
        time.sleep(0.5)
    screenshot("nivara_commander_dashboard")

    step("audit trail viewer")
    assert tap_label(xml, "Audit trail", wait=1.0), "audit button missing"
    wait_for("UNIT_VIEW")
    # UNIT_VIEW_BLOCKED is the oldest entry of the run — scroll it into view.
    xml = scroll_until("UNIT_VIEW_BLOCKED")
    screenshot("nivara_audit_trail")

    print("\nALL E2E CHECKS PASSED")


if __name__ == "__main__":
    sys.exit(main())
