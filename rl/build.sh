#!/bin/zsh
# Builds the policy data generator against the real engine sources, the same
# way bench/ is built (release, no app/UI code).
#
# Engine/ and Models/ are globbed so new engine files and model types are picked
# up automatically (the engine pulls in more of Models/ over time — a hand-kept
# list drifts). Services/ is NOT globbed: DataService/ScreenScanner/ResourceCache
# are app code (networking, ScreenCaptureKit, Vision); only IVCalculator is pure.
set -e
cd "$(dirname "$0")"

swiftc -O -o generate \
    main.swift \
    ../PokeParty/Engine/*.swift \
    ../PokeParty/Engine/Meta/*.swift \
    ../PokeParty/Models/*.swift \
    ../PokeParty/Services/IVCalculator.swift

echo "Built rl/generate"
