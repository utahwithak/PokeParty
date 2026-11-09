#!/bin/zsh
# Captures Mac App Store screenshots of the PokeParty window.
#
#   scripts/mac_screenshots.sh [width height [output-dir]]
#
# Width and height are the window size in points; on a Retina display the PNG is
# twice that. App Store sizes are 16:10: 1280x800, 1440x900, 2560x1600, 2880x1800
# pixels, so the default 1440x900 points gives 2880x1800 pixels.
#
# Each shot quits and relaunches the app on the tab named in SHOTS (the app
# restores its last tab from UserDefaults), resizes the window, optionally waits
# for you to set up the screen, then captures the window alone. Capturing by
# window id leaves out the menu bar, the Dock and the desktop, and `-o` leaves
# out the drop shadow.
#
# One-time setup:
#   - Build and run PokeParty from Xcode (Debug, so Pro is unlocked) once, then quit.
#     Set APP_PATH to that .app to launch a specific build, otherwise the
#     registered com.freebits.PokeParty is used.
#   - Give your terminal Accessibility access (System Settings > Privacy & Security)
#     so System Events can resize the window, and Screen Recording access for screencapture.
#   - Use a display at least as large as the window (plus the menu bar).
#
# This takes over the desktop while it runs; don't touch the mouse between shots
# unless a shot asks you to.

set -euo pipefail

WIDTH=${1:-1440}
HEIGHT=${2:-900}
OUT=${3:-$HOME/Desktop/PokeParty-Mac-Screenshots}

BUNDLE=com.freebits.PokeParty
PROCESS=PokeParty
PREFS="$HOME/Library/Containers/$BUNDLE/Data/Library/Preferences/$BUNDLE.plist"
HERE=${0:A:h}

# name|tab key|what to do before the capture (empty: capture straight away)
# Tab keys are SidebarSelection.persistenceKey values; a league is format:<cup>-<cp>.
SHOTS=(
    "01-rankings-great|format:all-1500|"
    "02-rankings-ultra|format:all-2500|"
    "03-team-builder|teamBuilder|Open a team with three Pokémon."
    "04-rank-checker|rankChecker|Enter IVs and pick a Pokémon, e.g. Charizard 15/15/15."
    "05-party-finder|partyFinder|Run a search and open the results."
    "06-battle-hud|battleHUD|Pick a saved team and add two opponents."
    "07-matchup|matchup|Pick two Pokémon so the results show."
    "08-bench|bench|Make sure the bench has several Pokémon."
)

mkdir -p "$OUT"

# The window has to fit on screen below the menu bar.
read -r _ _ SCREEN_W SCREEN_H <<< "$(osascript -e 'tell application "Finder" to get bounds of window of desktop' | tr -d ',')"
if (( WIDTH > SCREEN_W || HEIGHT + 40 > SCREEN_H )); then
    echo "A ${WIDTH}x${HEIGHT} window won't fit on a ${SCREEN_W}x${SCREEN_H} display; try 1280 800." >&2
    exit 1
fi

# Small helper that finds the window id; built into a scratch directory.
TOOLS=$(mktemp -d)
trap 'rm -rf "$TOOLS"' EXIT
swiftc -O "$HERE/windowid.swift" -o "$TOOLS/windowid"

quit_app() {
    osascript -e "tell application id \"$BUNDLE\" to quit" 2>/dev/null || true
    for _ in {1..40}; do
        pgrep -x "$PROCESS" >/dev/null || return 0
        sleep 0.25
    done
    pkill -x "$PROCESS" || true
}

launch_app() {
    if [[ -n ${APP_PATH:-} ]]; then open "$APP_PATH"; else open -b "$BUNDLE"; fi
    for _ in {1..80}; do
        "$TOOLS/windowid" "$PROCESS" >/dev/null 2>&1 && return 0
        sleep 0.25
    done
    echo "PokeParty didn't open a window." >&2
    exit 1
}

place_window() {
    osascript <<EOF
tell application "System Events" to tell process "$PROCESS"
    set frontmost to true
    set position of window 1 to {0, 40}
    set size of window 1 to {$WIDTH, $HEIGHT}
end tell
EOF
}

for shot in $SHOTS; do
    name=${shot%%|*}
    rest=${shot#*|}
    tab=${rest%%|*}
    prompt=${rest#*|}

    quit_app
    defaults write "$PREFS" PokeParty.selectedTab -string "$tab"
    launch_app
    place_window
    sleep 3   # rankings and saved teams load asynchronously

    if [[ -n $prompt ]]; then
        echo "[$name] $prompt  Press Return to capture."
        read -r
        place_window   # in case a sheet or popover moved things
    fi

    file="$OUT/$name.png"
    screencapture -o -l "$("$TOOLS/windowid" "$PROCESS")" "$file"

    pixels=$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ {printf "%s ", $2}')
    echo "[$name] $pixels-> $file"
done

quit_app
echo "Done. Check the sizes above against 1280x800, 1440x900, 2560x1600 or 2880x1800."
