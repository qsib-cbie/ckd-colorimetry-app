#!/bin/zsh
# usage: [CONFIG=Release] ios/scripts/device_ui_tests.sh <device UDID> [xcodebuild options such as -only-testing:CKDColorimetryUITests/WorkflowUITests]
set -e
R=${0:A:h:h:h}
DEVICE=${1:?device UDID, from xcrun xctrace list devices}
shift
CONFIG=${CONFIG:-Debug}
OUT=$R/tmp/device-ui-tests
P=$OUT/build/Build/Products/$CONFIG-iphoneos
(cd $R/ios/App && xcodegen generate --quiet)
xcodebuild build-for-testing -project $R/ios/App/CKDColorimetry.xcodeproj -scheme CKDColorimetry -configuration $CONFIG \
  -destination id=$DEVICE -derivedDataPath $OUT/build -allowProvisioningUpdates -quiet
xcrun devicectl device install app --device $DEVICE $P/CKDColorimetry.app
xcrun devicectl device copy to --device $DEVICE --domain-type appDataContainer \
  --domain-identifier edu.northwestern.bioelectronics.qsib.QCam --remove-existing-content true \
  --source $P/CKDColorimetryUITests-Runner.app/PlugIns/CKDColorimetryUITests.xctest/UITestFixtures \
  --destination Library/UITestFixtures
xcodebuild test-without-building -xctestrun $(ls $OUT/build/Build/Products/*iphoneos*.xctestrun | head -1) \
  -destination id=$DEVICE -resultBundlePath $OUT/results-$(date +%Y%m%d-%H%M%S).xcresult "$@"
