#!/usr/bin/env bash
# Render a hardened pd/<design> GDS to PNG using KLayout in batch mode.
# Auto-discovers the most recent OpenLane run under
# pd/<design>/runs/RUN_*/final/gds/<design>.gds.
#
# Usage:
#   scripts/gds_to_png.sh <design>                       # auto-find latest run
#   scripts/gds_to_png.sh <design> <out.png>             # explicit output path
#   scripts/gds_to_png.sh <design> <out.png> <long_side>
#   scripts/gds_to_png.sh <path/to/input.gds> <out.png>  # explicit GDS path
#
# Examples:
#   scripts/gds_to_png.sh mac_array_4x4
#   scripts/gds_to_png.sh int4_pe gds/int4_pe.png 8192
#
# Anything after the third positional is forwarded as `-rd key=value` to
# the python script (e.g. bg=#000000, margin=0.06, oversample=2, cell=...).
#
# Environment overrides:
#   KLAYOUT      path to klayout binary (default: klayout from PATH)
#   PDK_ROOT     PDK root             (default: ~/.volare)
#   PDK          PDK name             (default: sky130A)
#   LYP          explicit layer-properties .lyp (default: PDK's sky130A.lyp)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

usage() {
    sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 1
}

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "ERROR: missing <design> (or explicit <path/to/input.gds>) argument" >&2
    echo >&2
    usage
fi

ARG1="$1"

# If ARG1 looks like a path (ends in .gds), treat it as the explicit GDS.
# Otherwise treat it as a design name and auto-discover the latest run.
if [[ "$ARG1" == *.gds ]]; then
    GDS="$ARG1"
    DESIGN="$(basename "${GDS%.gds}")"
else
    DESIGN="$ARG1"
    RUNS_DIR="$ROOT/pd/$DESIGN/runs"
    LATEST="$(ls -1dt "$RUNS_DIR"/RUN_* 2>/dev/null | head -1 || true)"
    if [[ -z "$LATEST" ]]; then
        echo "ERROR: no OpenLane runs found under $RUNS_DIR" >&2
        echo "       harden the design first: cd pd && make DESIGN=$DESIGN harden" >&2
        exit 1
    fi
    GDS="$LATEST/final/gds/$DESIGN.gds"
fi

PNG="${2:-$ROOT/pd/$DESIGN/gds/$DESIGN.png}"
LONG_SIDE="${3:-4096}"
shift $(( $# < 3 ? $# : 3 )) || true

KLAYOUT_BIN="${KLAYOUT:-$(command -v klayout || true)}"
if [[ -z "$KLAYOUT_BIN" || ! -x "$KLAYOUT_BIN" ]]; then
    echo "ERROR: klayout not found on PATH; set KLAYOUT=/path/to/klayout" >&2
    exit 1
fi

if [[ ! -f "$GDS" ]]; then
    echo "ERROR: GDS file not found: $GDS" >&2
    exit 1
fi

PDK_ROOT="${PDK_ROOT:-$HOME/.volare}"
PDK="${PDK:-sky130A}"
LYP="${LYP:-$PDK_ROOT/$PDK/libs.tech/klayout/tech/$PDK.lyp}"

EXTRA_RD=()
if [[ -f "$LYP" ]]; then
    EXTRA_RD+=("-rd" "lyp=$LYP")
else
    echo "WARN: layer properties file not found: $LYP (falling back to klayout defaults)" >&2
fi

# Forward any remaining 'key=value' args verbatim as -rd flags.
for arg in "$@"; do
    EXTRA_RD+=("-rd" "$arg")
done

mkdir -p "$(dirname "$PNG")"

echo "[gds_to_png] klayout : $KLAYOUT_BIN"
echo "[gds_to_png] design  : $DESIGN"
exec "$KLAYOUT_BIN" -b -nc -z \
    -r "$HERE/gds_to_png.py" \
    -rd "gds=$GDS" \
    -rd "png=$PNG" \
    -rd "long_side=$LONG_SIDE" \
    "${EXTRA_RD[@]}"
