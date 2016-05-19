#!/bin/bash

set -e

SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname $SCRIPTS)

export REACT_PACKAGER_LOG="$ROOT/server.log"

cd $ROOT

function cleanup {
  EXIT_CODE=$?
  set +e
  echo "EXIT_CODE=$EXIT_CODE"
  echo "SERVER_PID=$SERVER_PID"
  if [ $EXIT_CODE -ne 0 ];
  then
    WATCHMAN_LOGS=/usr/local/Cellar/watchman/3.1/var/run/watchman/$USER.log
    [ -f $WATCHMAN_LOGS ] && cat $WATCHMAN_LOGS

    [ -f $REACT_PACKAGER_LOG ] && cat $REACT_PACKAGER_LOG
  fi
  SERVER_PID=$(lsof -n -i4TCP:8081 | grep 'LISTEN' | awk -F" " '{print $2}')
  [ $SERVER_PID ] && kill -9 $SERVER_PID
}
trap cleanup EXIT

./packager/packager.sh --nonPersistent &
SERVER_PID=$!
# TODO: We use xcodebuild because xctool would stall when collecting info about
# the tests before running them. Switch back when this issue with xctool has
# been resolved.
xcodebuild \
  -project Examples/UIExplorer/UIExplorer.xcodeproj \
  -scheme UIExplorer \
  -sdk macosx10.11 \
  -destination 'platform=OS X,arch=x86_64' \
  test
| xcpretty && exit ${PIPESTATUS[0]}
