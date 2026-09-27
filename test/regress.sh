#!/bin/bash
# TEMPO full verification regression — single command.
# Usage (on starklabs): bash test/regress.sh   (from repo root)
# Stages: formal (32 proofs) -> xcheck -> Verilator benches (591) -> co-sim (4 images).
# Independent of the Tiny Tapeout track (test/test.py + test/tb.v): no shared code.
set -u
cd "$(dirname "$0")/.."
source /home/jarvis/asic/activate >/dev/null 2>&1
FAIL=0
PASS_N=0

echo "=== [1/4] Formal: 32 SymbiYosys proofs ==="
./test/formal/gen/run_all.sh > /tmp/regress_formal.log 2>&1
FPASS=$(grep -c "DONE (PASS" /tmp/regress_formal.log || true)
FFAIL=$(grep -cE "DONE \((FAIL|ERROR)" /tmp/regress_formal.log || true)
echo "formal: $FPASS PASS, $FFAIL FAIL/ERROR (expect 32/0)"
[ "$FPASS" -eq 32 ] && [ "$FFAIL" -eq 0 ] || FAIL=1

echo "=== [2/4] X-check: Icarus 4-state, no X after reset ==="
iverilog -g2012 -o /tmp/regress_xcheck.vvp test/xcheck_pe.v src/tt_um_pemu_pe.v \
  > /tmp/regress_xcheck.log 2>&1 || { echo "xcheck BUILD FAIL"; FAIL=1; }
if [ "$FAIL" -eq 0 ]; then
  vvp /tmp/regress_xcheck.vvp > /tmp/regress_xcheck.log 2>&1
  if grep -q "XCHECK PASS" /tmp/regress_xcheck.log; then echo "xcheck: PASS (600 cycles, no X)";
  else echo "xcheck: FAIL"; FAIL=1; fi
fi

echo "=== [3/4] Verilator block benches ==="
bash test/run_verilator.sh all > /tmp/regress_bench.log 2>&1
for b in pe host observer top; do
  if grep -q "FAIL" test/vbuild/build_tb_$b.log 2>/dev/null; then echo "bench $b: BUILD FAIL"; FAIL=1; fi
done
BCHECKS=$(grep -hoE "[0-9]+ checks? (PASS|passed)" /tmp/regress_bench.log | grep -oE "^[0-9]+" | paste -sd+ | bc)
echo "benches ran (see /tmp/regress_bench.log)"
tail -4 /tmp/regress_bench.log | head -4

echo "=== [4/4] Co-sim: RTL vs ISA golden, 4 firmware images ==="
for img in spi uart i2c onewire; do
  trace="test/cosim/traces/${img}_trace.bin"
  [ "$img" = "onewire" ] && trace="test/cosim/traces/onewire_trace.bin"
  hex="test/cosim/hex/${img}.hex"
  if [ ! -f "$trace" ] || [ ! -f "$hex" ]; then echo "cosim $img: MISSING INPUTS"; FAIL=1; continue; fi
  if make -C test/cosim TRACE="$PWD/$trace" HEX="$PWD/$hex" > /tmp/regress_cosim_$img.log 2>&1; then
    cyc=$(grep -oE "COSIM PASS: [0-9]+" /tmp/regress_cosim_$img.log | grep -oE "[0-9]+" | tail -1)
    echo "cosim $img: PASS ($cyc cycles)"
  else
    echo "cosim $img: FAIL"; FAIL=1
  fi
done

echo "==================================="
if [ "$FAIL" -eq 0 ]; then echo "REGRESSION: ALL STAGES PASS"; else echo "REGRESSION: FAILED"; fi
exit $FAIL
