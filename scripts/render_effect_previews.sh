#!/bin/zsh
# Render every official effect preview scene (assets/effects/*/preview) at two times into out/effects/,
# plus the unmodified base texture, and print any renderer warnings.
set -u
cd "${0:A:h}/.."
A=samples/wallpaper_engine/assets
OUT=out/effects
mkdir -p $OUT
for d in $A/effects/*/preview $A/effects/vhs/previewvhs; do
  [ -f $d/project.json ] || continue
  n=$(basename $(dirname $d))
  log=$(mktemp)
  for t in 1 2.5; do
    .build/release/wecli render $d --assets $A --time $t --warm 0.5 --size 256x256 --out $OUT/${n}_t$t.png > $log 2>&1 \
      || echo "$n: FAILED $(tail -1 $log)"
  done
  base=$(ls $d/materials/*.tex 2>/dev/null | head -1)
  [ -n "$base" ] && .build/release/wecli tex2png $base $OUT/${n}_base.png 2>/dev/null
  grep -q warning $log && echo "$n: $(grep warning $log | sed 's/  warning: //' | sort -u | tr '\n' ';' | cut -c1-300)"
  rm -f $log
done
