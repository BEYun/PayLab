#!/bin/bash
# 전체 테스트: 단위·통합(PayLab 스킴, 커버리지 켬) → UI(PayLabUITests 스킴) → 커밋 hook 자체 테스트 → perf-report 테스트.
# 끝에서(성공·실패 모두) 성능 수집·판정: .build/perf/report.json.
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

perf_ready=0  # 테스트 단계에 들어가면 1. 마무리에서 성능 수집·판정을 할지 정한다
perf_dir=.build/perf
products=.build/DerivedData/Build/Products/Debug-iphonesimulator

finish() {  # EXIT trap: 성능 수집·판정 뒤 종료. 원래 실패면 원래 종료 코드를 유지한다
    local code=$?
    trap - EXIT
    set +e
    if [ "$perf_ready" = 1 ]; then
        local logs=() l
        for l in "$results/PayLab.log" "$results/PayLabUITests.log"; do
            [ -f "$l" ] && logs+=(--build-log "$l")
        done
        mkdir -p "$perf_dir"
        if python3 -I scripts/perf-report.py collect --since "$since" --device "$udid" \
            --products "$products" ${logs[@]+"${logs[@]}"} --out "$perf_dir/report.json"; then
            python3 -I scripts/perf-report.py report --input "$perf_dir/report.json" --where local
            if [ $? -ne 0 ] && [ "$code" -eq 0 ]; then
                echo "실패: 이번 변경의 성능 문제"
                code=1
            fi
        else
            echo "실패: 성능 수집"
            [ "$code" -eq 0 ] && code=1
        fi
    fi
    [ "$code" -eq 0 ] && echo "ALL TESTS PASSED"
    exit "$code"
}
trap finish EXIT

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
since=$(date '+%Y-%m-%d %H:%M:%S')
udid=$(grep -F "$sim (" <<< "$(xcrun simctl list devices)" | grep -oE '[0-9A-F-]{36}' | head -n 1)
rm -rf "$results"
mkdir -p "$results"
# 증분 빌드에서도 변경 파일의 컴파일 경고가 다시 나오게 한다
python3 -I scripts/perf-report.py changed-swift | xargs -I{} touch {}
perf_ready=1

run_tests PayLab -enableCodeCoverage YES
# 두 스킴이 앱을 똑같이(커버리지 켜고) 빌드해야 PayLab.debug.dylib이 다시 링크되지 않는다.
# 다르면 hang 기호화(perf-report collect)가 마지막 바이너리로 엉뚱한 함수 이름을 만든다.
run_tests PayLabUITests -enableCodeCoverage YES
scripts/test-hook.sh > "$results/hook.log" 2>&1 || fail "커밋 hook 테스트" "$results/hook.log"
echo "커밋 hook 테스트: $(grep -c '^PASS' "$results/hook.log")개 통과"
python3 -I scripts/test_perf_report.py > "$results/perf-report.log" 2>&1 || fail "perf-report 테스트" "$results/perf-report.log"
echo "perf-report 테스트: OK"
