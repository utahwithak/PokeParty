#!/bin/zsh
# Native-resolution App Store screenshots from the iOS simulators.
#
#   scripts/sim_screenshots.sh iphone|ipad [output-dir]
#
# Uses `simctl io screenshot`, which writes the simulator's real pixel size
# (iPhone 18 Pro Max 6.9": 1320x2868, iPad Pro 13": 2064x2752), unlike the
# point-sized images the Xcode device-interaction tools return. It also sets a
# clean 9:41 status bar with full battery and signal.
#
# PokeParty must already be installed on the simulator (run it once from Xcode).
# On iPad each shot relaunches the app on its tab; on iPhone the app opens on the
# sidebar, so every shot asks you to navigate. Press Return in the terminal to
# capture. Simulator builds have Pro unlocked.

set -euo pipefail

BUNDLE=com.freebits.PokeParty

case ${1:-} in
    iphone) DEVICE="iPhone 18 Pro Max"; KIND=iPhone ;;
    ipad)   DEVICE="iPad Pro 13-inch (M5)"; KIND=iPad ;;
    *) echo "Usage: $0 iphone|ipad [output-dir]" >&2; exit 1 ;;
esac
OUT=${2:-$HOME/Desktop/PokeParty-$KIND-Screenshots}

# name|tab key|what to do before the capture (empty: capture straight away on iPad)
SHOTS=(
    "01-rankings-great|format:all-1500|Open Great League rankings and select a Pokémon (e.g. Melmetal)."
    "02-rankings-ultra|format:all-2500|Open Ultra League rankings and select a Pokémon (e.g. Tinkaton)."
    "03-team-builder|teamBuilder|Open a team with three Pokémon (Melmetal, Altaria, Corviknight)."
    "04-rank-checker|rankChecker|Pick Charizard and enter 15/15/15."
    "05-party-finder|partyFinder|Run a search and open the results."
    "06-matchup|matchup|Pick Charizard vs Blastoise so the results show."
    "07-bench|bench|Make sure the bench has several Pokémon."
)
[[ $KIND == iPad ]] && SHOTS+=("08-battle-hud|battleHUD|Pick a saved team and add two opponents.")

UDID=$(xcrun simctl list devices available | grep -F "$DEVICE (" | head -1 | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}')
if [[ -z $UDID ]]; then echo "No '$DEVICE' simulator found." >&2; exit 1; fi

mkdir -p "$OUT"
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

for shot in $SHOTS; do
    name=${shot%%|*}
    rest=${shot#*|}
    tab=${rest%%|*}
    prompt=${rest#*|}

    xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
    xcrun simctl spawn "$UDID" defaults write "$BUNDLE" PokeParty.selectedTab -string "$tab"
    xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
    sleep 4   # rankings and saved teams load asynchronously

    echo "[$name] $prompt  Press Return to capture."
    read -r

    file="$OUT/$name.png"
    xcrun simctl io "$UDID" screenshot --type=png "$file" 2>/dev/null
    pixels=$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ {printf "%s ", $2}')
    echo "[$name] $pixels-> $file"
done

xcrun simctl status_bar "$UDID" clear
echo "Done. App Store needs 1320x2868 (iPhone 6.9\") or 2064x2752 (iPad 13\")."
