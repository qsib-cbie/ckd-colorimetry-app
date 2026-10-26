#!/bin/zsh
# usage: ios/scripts/stats/run_all.sh <output directory> [previous release tag, default 2.0]
set -e
R=${0:A:h:h:h:h}
OUT=${1:?output directory}
PREV=${2:-2.0}
PY=${PYTHON:-python3}
F=$R/api/tests/fixtures
mkdir -p $OUT
rm -rf $OUT/mac-prev && mkdir -p $OUT/mac-prev && git -C $R archive $PREV api | tar -x -C $OUT/mac-prev
swift build -c release --package-path $R/ios/CKDKit --product ckd-contract > /dev/null
CKD=$R/ios/CKDKit/.build/release/ckd-contract
cases=(cr2_standard24:SampleImg1.CR2:cr2_standard24:1 dng_standard24:iPhoneRAW.DNG:dng_standard24:1
       dng_flower_auto:_NOT_ACTUAL_TEST.dng:dng_flower_auto:1 dng_flower_manual:_NOT_ACTUAL_TEST.dng:dng_flower_manual:1)
[[ -f $R/tmp/large/ProRAW48.DNG ]] && cases+=(prores48:$R/tmp/large/ProRAW48.DNG:dng_standard24:2)
for spec in $cases; do
  IFS=: read name raw doc scale <<< "$spec"
  [[ $raw = /* ]] || raw=$F/$raw
  D=$OUT/runs/$name; rm -rf $D; mkdir -p $D
  for i in 1 2 3; do
    /usr/bin/time -l $CKD --run $F/mac_reference/pipeline/$doc.json --raw $raw --output $D/ios-$i --scale $scale > /dev/null 2> $D/ios-$i.time
    $PY -c "import json; json.dump(json.load(open('$D/ios-$i/ios.json'))['identity'], open('$D/identity.json', 'w'))"
    /usr/bin/time -l $PY $R/ios/scripts/stats/run_mac_engine.py --api $R/api --raw $raw --document $F/mac_reference/pipeline/$doc.json --scale $scale --identity $D/identity.json --out $D/mac21-$i.json 2> $D/mac21-$i.time
    /usr/bin/time -l $PY $R/ios/scripts/stats/run_mac_engine.py --api $OUT/mac-prev/api --raw $raw --document $F/mac_reference/pipeline/$doc.json --scale $scale --out $D/mac20-$i.json 2> $D/mac20-$i.time
  done
  echo "done $name"
done
$PY $R/ios/scripts/stats/compare.py $OUT
