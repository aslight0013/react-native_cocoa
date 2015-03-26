#!/bin/sh

# Run from react-native root

set -e

if [ -z "$1" ]
  then
    echo "You must supply an OS version as the first arg, e.g. 8.1 or 8.2"
    exit 255
fi

xctool \
  -project IntegrationTests/IntegrationTests.xcodeproj \
  -scheme IntegrationTests \
  -sdk iphonesimulator8.1 \
  -destination "platform=iOS Simulator,OS=${1},name=iPhone 5" \
  build test

xctool \
  -project Examples/UIExplorer/UIExplorer.xcodeproj \
  -scheme UIExplorer \
  -sdk iphonesimulator8.1 \
  -destination "platform=iOS Simulator,OS=${1},name=iPhone 5" \
  build test
