#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter create --platforms=android,linux,windows --project-name ferrypane --org top.mirv . >/dev/null
rm -f test/widget_test.dart # Flutter template test references an unrelated MyApp
python3 tool/patch_android.py
flutter pub get
