#!/bin/bash
# 전체 테스트: 단위·통합(PayLab 스킴, 커버리지 켬) → UI(PayLabUITests 스킴) → 커밋 hook 자체 테스트.
# 커밋 hook이 이 스크립트를 돌린다. 사람·Claude도 직접 실행한다. 결과·로그: .build/TestResults/
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
results=.build/TestResults
sim="PayLab-$(git branch --show-current)"
destination="platform=iOS Simulator,name=$sim"

fail() {  # fail <무엇> [로그]
    echo "실패: $1"
    if [ -n "${2:-}" ]; then
        grep -E "error:|✘|^FAIL|TEST FAILED" "$2" | grep -v "Executed 0 tests" | head -30 || true
        echo "로그: $2"
    fi
    exit 1
}

run_tests() {  # run_tests <스킴> [xcodebuild 옵션...]
    local scheme=$1 log="$results/$1.log"
    shift
    xcodebuild -workspace PayLab.xcworkspace -scheme "$scheme" -destination "$destination" \
        -derivedDataPath .build/DerivedData -resultBundlePath "$results/$scheme.xcresult" "$@" test \
        > "$log" 2>&1 || fail "$scheme 테스트" "$log"
    grep -E "✔ Test run" "$log" || true
    grep -E "Executed [1-9][0-9]* tests?," "$log" | tail -n 1 || true
}

tuist generate --no-open > /dev/null || fail "tuist generate"
devices=$(xcrun simctl list devices)
grep -qF "$sim (" <<< "$devices" \
    || xcrun simctl create "$sim" com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro > /dev/null \
    || fail "시뮬레이터 생성 ($sim)"
xcrun simctl boot "$sim" 2> /dev/null || true  # 이미 켜져 있으면 실패하므로 무시
xcrun simctl bootstatus "$sim" -b > /dev/null || fail "시뮬레이터 부팅 ($sim)"
rm -rf "$results"
mkdir -p "$results"

run_tests PayLab -enableCodeCoverage YES
run_tests PayLabUITests
scripts/test-hook.sh > "$results/hook.log" 2>&1 || fail "커밋 hook 테스트" "$results/hook.log"
echo "커밋 hook 테스트: $(grep -c '^PASS' "$results/hook.log")개 통과"
echo "ALL TESTS PASSED"
