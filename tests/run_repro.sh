#!/bin/bash
# run_repro.sh — 运行 ChargeLimiter daemon sqlite 并发竞态的最小复现。
#
# 期望（TDD 语义）：
#   baseline 无锁（镜像当前 daemon）  -> 应出现 sanitizer 报告或直接崩溃
#   locked   （修复目标，统一加锁）     -> 必须干净运行
#
# 用法：tests/run_repro.sh [迭代次数（默认 20000）]
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/sqlite_race_repro.c"
WORK=/tmp/chargelimiter_repro
LOG="$WORK/logs"
ITERS="${1:-20000}"
mkdir -p "$LOG"

build() { # name extra-cflags
  clang -O1 -g -pthread "$SRC" -lsqlite3 $2 -o "$WORK/$1" >/dev/null 2>&1 \
    && clang -O1 -g -pthread -fsanitize=thread $2 "$SRC" -lsqlite3 -o "$WORK/${1}_tsan" >/dev/null 2>&1 \
    && clang -O1 -g -pthread -fsanitize=address $2 "$SRC" -lsqlite3 -o "$WORK/${1}_asan" >/dev/null 2>&1
}

echo "== 构建（nolock = 当前 daemon 行为；locked = 强制修复）=="
build nolock "" || { echo "build failed"; exit 1; }
build locked "-DUSE_LOCK=1" || { echo "build failed"; exit 1; }

echo
echo "=== 1) baseline 无锁 + ASan：期望捕获 use-after-free / 越界 ==="
BA_EC=0 BA_CNT=0
"$WORK/nolock_asan" "$ITERS" >"$LOG/baseline_asan.log" 2>&1 || BA_EC=$?
BA_CNT=$(grep -c 'ERROR: AddressSanitizer' "$LOG/baseline_asan.log" || true)
echo "exit=$BA_EC  ASan 报告数=$BA_CNT"

echo
echo "=== 2) baseline 无锁 + TSan：期望捕获 db 数据竞争 ==="
BT_EC=0 BT_CNT=0
"$WORK/nolock_tsan" "$ITERS" >"$LOG/baseline_tsan.log" 2>&1 || BT_EC=$?
BT_CNT=$(grep -c 'WARNING: ThreadSanitizer: data race' "$LOG/baseline_tsan.log" || true)
echo "exit=$BT_EC  TSan 数据竞争数=$BT_CNT"

echo
echo "=== 3) baseline 无锁 + 无 sanitizer：期望（概率性）崩溃 ==="
BC_EC=0
"$WORK/nolock" "$ITERS" >"$LOG/baseline_plain.log" 2>&1 || BC_EC=$?
echo "exit=$BC_EC (非0=崩溃)"
tail -c 160 "$LOG/baseline_plain.log" | tr "\n" " "; echo

echo
echo "=== 4) 修复验证 locked + TSan：期望零报告 ==="
LC_EC=0 LC_CNT=0
"$WORK/locked_tsan" "$ITERS" >"$LOG/locked_tsan.log" 2>&1 || LC_EC=$?
LC_CNT=$(grep -c 'WARNING: ThreadSanitizer: data race' "$LOG/locked_tsan.log" || true)
echo "exit=$LC_EC  TSan data race 数=$LC_CNT"

echo
echo "===  结果 ==="
if [ "$BA_CNT" -gt 0 ] || [ "$BT_CNT" -gt 0 ] || [ "$BA_EC" -ne 0 ] || [ "$BT_EC" -ne 0 ] || [ "$BC_EC" -ne 0 ]; then
  echo "PASS_REPRODUCED: 无锁 baseline 出现竞态/越界/崩溃（当前 daemon 行为不安全）"
else
  echo "NOISE_THIS_RUN: 本次未捕获（概率性，可加大迭代或重跑）"
fi
if [ "$LC_CNT" -eq 0 ] && [ "$LC_EC" -eq 0 ]; then
  echo "PASS_FIX_CLEAN: 加锁修复后 sanitizer 干净"
else
  echo "FAIL_FIX: 加锁修复下仍有问题 (exit=$LC_EC counts=$LC_CNT)"
fi
echo