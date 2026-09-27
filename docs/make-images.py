#!/usr/bin/env python3
"""Generate the published images for this repo: a GitHub social preview card and a README hero.

The terminal text is a real captured session from tests/mock-adb (see CAPTURE below), not a mock-up.
Everything is drawn with PIL, so the assets are reproducible:

    python3 docs/make-images.py

Only needs DejaVu fonts (present on most Linux systems) and pillow:

    pip install pillow
"""

import pathlib
import re
from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
FONT_DIR = "/usr/share/fonts/truetype/dejavu"

# --- palette (GitHub dark) -------------------------------------------------
BG = (13, 17, 23)
BG_CARD = (22, 27, 34)
BG_BAR = (33, 38, 45)
BORDER = (48, 54, 61)
FG = (230, 237, 243)
FG_DIM = (139, 148, 158)
ACCENT = (88, 166, 255)
GREEN = (63, 185, 80)
AMBER = (210, 153, 34)
CYAN = (57, 197, 187)
RED = (248, 81, 73)

# --- a real session, captured while running the wizard against tests/mock-adb --
CAPTURE = """\
== Projectivy Launcher - setup wizard
This removes the ads from an Amazon Fire TV Stick by making Projectivy Launcher the home screen,
and can optionally stop Amazon's updates from arriving and undoing it again.

What would you like to do?
  1: Set up the Firestick launcher
  2: Undo / restore the Amazon home screen
  3: Exit Setup
selected: 1: Set up the Firestick launcher

== Step 2 of 6 - installing Projectivy
How should Projectivy be installed?
  1: Install Projectivy for me over ADB (recommended)
  2: I have already installed it on the TV with Downloader
selected: 1: Install Projectivy for me over ADB (recommended)

== Step 4 of 6 - connecting to 192.168.1.100:5555
LOOK AT THE TV NOW. A message will appear asking whether to allow USB debugging.
  OK connected to 192.168.1.100

== Step 5 of 6 - applying the changes
  OK Projectivy installed
  OK accessibility service registered

== Checking the result
  OK PASS - the stick rebooted and came back to Projectivy

== Optional - stop Amazon pushing updates over it
  1: NextDNS profile (recommended - the only one that blocks Amazon updates)
selected: 1: NextDNS profile (recommended - the only one that blocks Amazon updates)
  OK softwareupdates.amazon.com is blocked
"""

SOCIAL_LINES = [
    "== Projectivy Launcher - setup wizard",
    "How should Projectivy be installed?",
    "  1: Install Projectivy for me over ADB (recommended)",
    "  2: I have already installed it on the TV with Downloader",
    "selected: 1: Install Projectivy for me over ADB",
    "",
    "== Step 4 of 6 - connecting to 192.168.1.100:5555",
    "LOOK AT THE TV NOW. Press Allow on the remote.",
    "  OK connected to 192.168.1.100",
    "",
    "== Step 5 of 6 - applying the changes",
    "  OK Projectivy installed",
    "  OK accessibility service registered",
    "",
    "== Checking the result",
    "  OK PASS - the stick rebooted and came back",
    "     to Projectivy",
]

# A shorter excerpt for the README hero, ending on the DNS verification.
HERO_LINES = [
    "== Projectivy Launcher - setup wizard",
    "",
    "What would you like to do?",
    "  1: Set up the Firestick launcher",
    "  2: Undo / restore the Amazon home screen",
    "selected: 1: Set up the Firestick launcher",
    "",
    "== Step 2 of 6 - installing Projectivy",
    "How should Projectivy be installed?",
    "  1: Install Projectivy for me over ADB (recommended)",
    "  2: I have already installed it on the TV with Downloader",
    "selected: 1: Install Projectivy for me over ADB",
    "",
    "== Step 4 of 6 - connecting to 192.168.1.100:5555",
    "LOOK AT THE TV NOW. A message will appear asking whether",
    "to allow USB debugging.",
    "  OK connected to 192.168.1.100",
    "",
    "== Step 5 of 6 - applying the changes",
    "  OK Projectivy installed",
    "  OK accessibility service registered",
    "",
    "== Checking the result",
    "  OK PASS - the stick rebooted and came back to Projectivy",
    "",
    "== Optional - stop Amazon pushing updates over it",
    "  1: NextDNS profile (recommended - blocks Amazon updates)",
    "selected: 1: NextDNS profile (recommended - blocks Amazon updates)",
    "  OK softwareupdates.amazon.com is blocked",
]


def font(name, size):
    return ImageFont.truetype(f"{FONT_DIR}/{name}", size)


MONO = "DejaVuSansMono.ttf"
MONO_B = "DejaVuSansMono-Bold.ttf"
SANS = "DejaVuSans.ttf"
SANS_B = "DejaVuSans-Bold.ttf"


def line_colour(text):
    s = text.strip()
    if s.startswith("=="):
        return CYAN
    if s.startswith("OK"):
        return GREEN
    if s.startswith("!!"):
        return AMBER
    if s.startswith("XX"):
        return RED
    if s.startswith("selected"):
        return FG_DIM
    return FG


def wrap(text, fnt, width, draw):
    words, out, cur = text.split(), [], ""
    for w in words:
        trial = f"{cur} {w}".strip()
        if draw.textlength(trial, font=fnt) <= width:
            cur = trial
        else:
            if cur:
                out.append(cur)
            cur = w
    if cur:
        out.append(cur)
    return out


def terminal_card(draw, x, y, w, h, title, lines, mono_size=15, pad=18, radius=10):
    draw.rounded_rectangle([x, y, x + w, y + h], radius=radius, fill=BG_CARD, outline=BORDER)
    draw.rounded_rectangle([x, y, x + w, y + 34], radius=radius, fill=BG_BAR)
    draw.rectangle([x, y + 24, x + w, y + 34], fill=BG_BAR)
    for i, c in enumerate(((255, 95, 86), (255, 189, 46), (39, 201, 63))):
        cx = x + 18 + i * 20
        draw.ellipse([cx, y + 12, cx + 10, y + 22], fill=c)
    draw.text((x + 84, y + 9), title, font=font(SANS, 14), fill=FG_DIM)

    fnt = font(MONO, mono_size)
    ty = y + 34 + pad
    for line in lines:
        if ty + mono_size + 4 > y + h - pad:
            break
        draw.text((x + pad, ty), line, font=fnt, fill=line_colour(line))
        ty += int(mono_size * 1.45)
    return ty


def fit(text, name, start, max_width, draw, floor=12):
    """Largest size at or below `start` whose rendered width fits max_width."""
    size = start
    while size > floor and draw.textlength(text, font=font(name, size)) > max_width:
        size -= 1
    return font(name, size), size


# ---------------------------------------------------------------- social card
def social_preview():
    W, H = 1280, 640
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    # soft vertical wash + accent stripe
    for i in range(H):
        t = i / H
        d.line([(0, i), (W, i)], fill=(
            int(BG[0] + 10 * t), int(BG[1] + 14 * t), int(BG[2] + 22 * t)))
    d.rectangle([0, 0, 6, H], fill=ACCENT)

    COL = 596                      # left text column, measured from x=56
    CARD_X, CARD_Y, CARD_W = 700, 92, 524
    CARD_H = 34 + 36 + len(SOCIAL_LINES) * 21

    t1, s1 = fit("Projectivy Launcher", SANS_B, 50, COL, d)
    d.text((56, 54), "Projectivy Launcher", font=t1, fill=FG)
    t2, s2 = fit("installer for Amazon Fire TV Stick and Cube", SANS, 24, COL, d)
    d.text((56, 54 + s1 + 12), "installer for Amazon Fire TV Stick and Cube", font=t2, fill=FG)
    t3, s3 = fit("Fire OS 7/8  -  no root  -  Windows, Linux, macOS", SANS, 21, COL, d)
    d.text((56, 54 + s1 + 12 + s2 + 10), "Fire OS 7/8  -  no root  -  Windows, Linux, macOS",
           font=t3, fill=FG_DIM)
    rule_y = 54 + s1 + 12 + s2 + 10 + s3 + 22
    d.line([(56, rule_y), (56 + COL, rule_y)], fill=BORDER, width=2)

    bullets = [
        "Staged wizard for Windows and Linux, plus a CLI for repeat jobs",
        "Installs Projectivy over your network, then verifies it after a reboot",
        "Optional DNS block so Amazon's update servers are unreachable",
        "49 regression checks, and no Fire TV needed to run them",
    ]
    y = rule_y + 26
    bf = font(SANS, 21)
    for b in bullets:
        lines = wrap(b, bf, COL - 30, d)
        d.ellipse([58, y + 8, 68, y + 18], fill=CYAN)
        for i, chunk in enumerate(lines):
            d.text((86, y + i * 27), chunk, font=bf, fill=FG)
        y += 27 * len(lines) + 14

    url = "github.com/Absolute-Projects-Public/projectivy-installer"
    uf, _ = fit(url, MONO, 19, COL + 40, d)
    d.text((56, H - 62), url, font=uf, fill=FG_DIM)

    terminal_card(d, CARD_X, CARD_Y, CARD_W, CARD_H, "Install-Projectivy.sh", SOCIAL_LINES, mono_size=14)
    assert CARD_X + CARD_W <= W - 20, "card runs off the right edge"
    assert CARD_Y + CARD_H <= H - 20, "card runs off the bottom"
    img.save(HERE / "social-preview.png")
    print("wrote social-preview.png", img.size, f"(title {s1}px, card {CARD_W}x{CARD_H})")


# ---------------------------------------------------------------- readme hero
def hero():
    W = 1200
    mono, pad, bar = 15, 18, 34
    H = bar + 2 * pad + len(HERO_LINES) * int(mono * 1.45) + 84 + 44
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    d.text((40, 18), "Projectivy Launcher installer", font=font(SANS_B, 24), fill=FG)
    right = "Linux / macOS wizard"
    d.text((W - 40 - d.textlength(right, font=font(SANS, 17)), 24), right,
           font=font(SANS, 17), fill=FG_DIM)
    d.line([(0, 54), (W, 54)], fill=BORDER, width=2)
    terminal_card(d, 40, 84, W - 80, bar + 2 * pad + len(HERO_LINES) * int(mono * 1.45),
                  "bash  ./Install-Projectivy.sh", HERO_LINES, mono_size=mono)
    img.save(HERE / "hero-wizard.png")
    print("wrote hero-wizard.png", img.size)


if __name__ == "__main__":
    social_preview()
    hero()