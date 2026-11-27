#!/bin/bash
# Live integration against the Mac mini test server. Does not touch 8787, Garage, TEAM_ROSTER.json, or the vault.
set -euo pipefail
cd "$(dirname "$0")/../Packages/ReaderSync"
READER_SYNC_LIVE=1 swift test --filter LiveIntegrationTests
