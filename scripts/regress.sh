#!/bin/zsh
# Pixel + warning regression suite.
#
#   scripts/regress.sh [--update] [--jobs N] [--no-build] [name-filter-regex]
#
# Renders every case in regression/cases.txt with wecli, compares the image (exact) and the sorted
# renderer warnings against the stored reference, and prints one PASS/FAIL summary (exit 1 on any
# failure). --update (re)writes the references instead ("bless" after an intended change).
#
# References are renders of Wallpaper Engine assets, so they are not committed: they live in
# $REGRESSION_REFS (default regression/refs, gitignored). Samples come from $SAMPLES (default samples).
set -u
zmodload zsh/datetime   # $EPOCHREALTIME
cd "${0:A:h}/.."
ROOT=$PWD
SAMPLES=${SAMPLES:-$ROOT/samples}
REFS=${REGRESSION_REFS:-$ROOT/regression/refs}
CURRENT=$ROOT/regression/current
DIFFS=$ROOT/regression/diff
WECLI=$ROOT/.build/release/wecli

# --- one case (invoked through xargs) --------------------------------------------------------------
if [[ ${1:-} == --case ]]; then
  mode=$2; shift 2
  name=$1 wallpaper=$2; shift 2
  out=$CURRENT/$name.png warnings=$CURRENT/$name.warnings.txt
  mkdir -p ${out:h}
  log=$("$WECLI" render "$SAMPLES/$wallpaper" --assets "$SAMPLES/wallpaper_engine/assets" "$@" --out "$out" 2>&1)
  if [[ $? != 0 || ! -f $out ]]; then
    echo "ERROR    $name: $(print -r -- $log | tail -1)"; exit 0
  fi
  print -r -- $log | grep '^  warning:' | sort > $warnings
  ref=$REFS/$name.png refw=$REFS/$name.warnings.txt
  if [[ $mode == update ]]; then
    mkdir -p ${ref:h}; cp $out $ref; cp $warnings $refw
    echo "UPDATED  $name"; exit 0
  fi
  if [[ ! -f $ref ]]; then echo "MISSING  $name (no reference; run with --update)"; exit 0; fi
  mkdir -p ${DIFFS}/${name:h}
  result=$("$WECLI" compare $out $ref --diff $DIFFS/$name.png)
  pixels_ok=$?
  warnings_ok=0
  cmp -s $warnings $refw || warnings_ok=1
  if [[ $pixels_ok == 0 && $warnings_ok == 0 ]]; then
    echo "PASS     $name"
  else
    reasons=()
    [[ $pixels_ok != 0 ]] && reasons+=("pixels: $result")
    [[ $warnings_ok != 0 ]] && reasons+=("warnings: $(diff $refw $warnings | grep '^[<>]' | sed 's/^</-/;s/^>/+/' | tr '\n' ' ')")
    echo "FAIL     $name — ${(j:; :)reasons}"
  fi
  exit 0
fi

# --- driver ----------------------------------------------------------------------------------------
mode=check jobs=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo 4) build=1 filter=''
while (( $# )); do
  case $1 in
    --update) mode=update ;;
    --jobs) jobs=$2; shift ;;
    --no-build) build=0 ;;
    -h|--help) sed -n '2,12p' $0; exit 0 ;;
    *) filter=$1 ;;
  esac
  shift
done

if (( build )); then
  swift build -c release 2>&1 | grep -E 'error|warning:' && { echo "build failed"; exit 1; }
fi
[[ -d $SAMPLES/wallpaper_engine/assets ]] || { echo "no Wallpaper Engine assets under $SAMPLES"; exit 1; }

rm -rf $CURRENT $DIFFS
mkdir -p $CURRENT
start=$EPOCHREALTIME
results=$(grep -v '^\s*#' regression/cases.txt | grep -v '^\s*$' | { [[ -n $filter ]] && grep -E -- "^\S*($filter)" || cat } |
  xargs -P $jobs -L 1 $0 --case $mode | sort)
elapsed=$(( EPOCHREALTIME - start ))

print -r -- $results | grep -v '^PASS\|^UPDATED'
total=$(print -r -- $results | grep -c .)
for s in PASS FAIL MISSING ERROR UPDATED; do
  typeset "n_$s=$(print -r -- $results | grep -c "^$s")"
done
echo
if [[ $mode == update ]]; then
  printf "Updated %d reference(s) in %s (%.1fs)\n" $n_UPDATED $REFS $elapsed
  exit $(( n_ERROR > 0 ))
fi
printf "%d case(s): %d passed, %d failed, %d missing, %d errors  (%.1fs, %d jobs)\n" \
  $total $n_PASS $n_FAIL $n_MISSING $n_ERROR $elapsed $jobs
if (( n_FAIL + n_MISSING + n_ERROR > 0 )); then
  (( n_FAIL )) && echo "Difference images (black = equal): $DIFFS"
  echo "RESULT: FAIL"; exit 1
fi
echo "RESULT: PASS"
