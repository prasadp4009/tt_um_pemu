#!/bin/bash
# run_verilator.sh -- build & run the four Worker-D block benches with Verilator.
# Usage (from repo root): bash test/run_verilator.sh [pe|host|observer|top|all] [--cov] [extra verilator args...]
# Benches are fully separate from the TT track (test/test.py + test/tb.v).
cd "$(dirname "$0")/.."
source /home/jarvis/asic/activate >/dev/null
WHAT="${1:-all}"; shift || true
COV=0
if [ "$WHAT" = "--cov" ]; then COV=1; WHAT="${1:-all}"; shift || true; fi
EXTRA="$*"
WNO="-Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-IMPERFECTSCH"
TRACE="--trace --trace-depth 99"
[ "$COV" -eq 1 ] && TRACE="--coverage --coverage-line --coverage-toggle"
run_one() {
    local name="$1" top="$2"; shift 2
    echo "=== $name ==="
    verilator --timing --cc --exe --build --main --top-module "$top" $WNO $TRACE $EXTRA "$@" \
        --Mdir "test/vbuild/obj_$name" -o "V$name" > "test/vbuild/build_$name.log" 2>&1 \
        || { tail -30 "test/vbuild/build_$name.log"; return 1; }
    ./test/vbuild/obj_$name/V$name 2>&1 | tail -30
}
SRAM=test/sram_sim.v
case "$WHAT" in
  pe)       run_one tb_pe tb_pe test/tb_pe.v src/tt_um_pemu_pe.v $SRAM ;;
  host)     run_one tb_host tb_host test/tb_host.v src/tt_um_pemu_host.v ;;
  observer) run_one tb_observer tb_observer test/tb_observer.v src/tt_um_pemu_observer.v $SRAM ;;
  top)      run_one tb_top tb_top test/tb_top.v $SRAM src/tt_um_pemu.v src/tt_um_pemu_pe.v src/tt_um_pemu_observer.v src/tt_um_pemu_host.v ;;
  all)      for b in pe host observer top; do bash "$0" ${COV:+--cov} "$b" $EXTRA || exit 1; done ;;
  *) echo "unknown: $WHAT"; exit 1 ;;
esac
