#!/usr/bin/env bash
# Add the Projectivy wizard to this machine's application menu (and desktop, if there is one).
#
#   ./add-to-app-menu.sh
#
# Why this exists: a .desktop file that says `cd "$(dirname %k)"` is portable but depends on the desktop
# environment expanding %k the way it should, and on the file being marked trusted. This writes a copy
# with the absolute path baked in, which works everywhere, and drops it in the menu.
#
# Undo: rm ~/.local/share/applications/install-projectivy.desktop

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
WIZ="$DIR/Install-Projectivy.sh"
APPS="$HOME/.local/share/applications"
DESK="$APPS/install-projectivy.desktop"

[ -f "$WIZ" ] || { echo "Cannot find Install-Projectivy.sh next to this script ($DIR)"; exit 1; }
chmod +x "$WIZ" 2>/dev/null || true
mkdir -p "$APPS"

# The trailing read keeps the terminal window open so the final message is readable.
printf '%s\n' \
  "[Desktop Entry]" \
  "Type=Application" \
  "Version=1.0" \
  "Name=Projectivy Launcher setup" \
  "GenericName=Fire TV Stick setup" \
  "Comment=Replace the Amazon Fire TV home screen with Projectivy Launcher" \
  "Exec=bash -c 'cd \"$DIR\"; bash ./Install-Projectivy.sh; printf \"\\nPress Enter to close. \"; read -r _ || true'" \
  "Terminal=true" \
  "Icon=video-television" \
  "StartupNotify=true" \
  "Categories=Utility;System;" \
  "Keywords=firetv;firestick;projectivy;amazon;adb;" \
  > "$DESK"
chmod +x "$DESK"

# A copy on the desktop too, if this machine has one. Some file managers need it marked executable,
# and some also need "Allow launching" ticked once.
if [ -d "$HOME/Desktop" ]; then
  cp "$DESK" "$HOME/Desktop/Install Projectivy.desktop"
  chmod +x "$HOME/Desktop/Install Projectivy.desktop"
  # KDE/GNOME use this flag to trust a desktop file that was copied rather than installed
  command -v gio >/dev/null 2>&1 && gio set "$HOME/Desktop/Install Projectivy.desktop" metadata::trusted true 2>/dev/null || true
  echo "Desktop shortcut: $HOME/Desktop/Install Projectivy.desktop"
fi

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" 2>/dev/null || true

echo "Menu entry: $DESK"
echo
echo "Look for 'Projectivy Launcher setup' in your applications menu, or run it directly:"
echo "  $WIZ"
echo
echo "If it does not appear, log out and back in, or launch it from the same folder:"
echo "  ./Install-Projectivy.desktop"