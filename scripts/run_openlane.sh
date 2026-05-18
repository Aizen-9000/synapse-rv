#!/usr/bin/env bash
# =============================================================================
#  Synapse-RV — OpenLane 2 GDS-II Flow
#  Usage: ./scripts/run_openlane.sh [npu_pe|npu_top|soc]
#  
#  Prerequisites:
#    pip install openlane         (OpenLane 2 — installs Yosys, OpenROAD, Magic)
#    OR use Docker:
#    docker pull efabless/openlane2:latest
# =============================================================================
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-npu_pe}"

case "$TARGET" in
  npu_pe|npu_top|soc) ;;
  *) echo "Usage: $0 [npu_pe|npu_top|soc]"; exit 1 ;;
esac

CONFIG="$ROOT/openlane/$TARGET/config.json"
echo "======================================================"
echo "  Synapse-RV OpenLane Flow: $TARGET"
echo "  Config: $CONFIG"
echo "======================================================"

# Method 1: OpenLane 2 Python package (recommended)
if command -v openlane &>/dev/null; then
  echo "[run] Using openlane Python package"
  cd "$ROOT"
  openlane "$CONFIG"

# Method 2: Docker (fallback)
elif command -v docker &>/dev/null; then
  echo "[run] Using Docker"
  docker run --rm \
    -v "$ROOT:/project" \
    -e DESIGN_NAME="$TARGET" \
    efabless/openlane2:latest \
    bash -c "openlane /project/openlane/$TARGET/config.json"

else
  echo ""
  echo "ERROR: Neither 'openlane' nor 'docker' found."
  echo ""
  echo "Install OpenLane 2:"
  echo "  pip install openlane"
  echo ""
  echo "Or install Docker then pull:"
  echo "  docker pull efabless/openlane2:latest"
  exit 1
fi

echo ""
echo "======================================================"
echo "  GDS output: $ROOT/runs/$TARGET/*/final/gds/"
echo "  View:  klayout runs/$TARGET/*/final/gds/*.gds"
echo "======================================================"
