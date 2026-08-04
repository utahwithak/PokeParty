#!/bin/zsh
# Builds the shield-policy data generator against the real engine sources,
# the same way bench/ is built (release, no app/UI code).
set -e
cd "$(dirname "$0")"

swiftc -O -o generate \
    main.swift \
    ../PokeParty/Engine/*.swift \
    ../PokeParty/Models/Move.swift \
    ../PokeParty/Models/Pokemon.swift \
    ../PokeParty/Models/Team.swift \
    ../PokeParty/Services/IVCalculator.swift

echo "Built rl/generate"
