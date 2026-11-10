# PayLab — 토스 iOS 벤치마킹 샘플 앱

토스 iOS를 참고해 디버깅·테스트·CI·트랜잭션·성능 자동화를 Claude Code로 익히는 샘플 앱.
설계: docs/superpowers/specs/2026-11-06-foundation-design.md

## 세션 운영
- 주제별 별도 세션: 디버깅 / 테스트 / CI (동시) → 트랜잭션 (테스트 후) → 성능 (CI 후)
- 세션마다 git 브랜치(worktree)를 나눈다. 새 worktree에서는 먼저 프로젝트 생성 명령을 실행한다.
- 자기 주제 밖의 것을 미리 구현하지 않는다.

## 모듈
| 모듈 | 역할 | 의존 |
|---|---|---|
| PayLab (App) | 조립: DataKit 구현체를 Feature에 주입, 화면 전환 | 모든 모듈 |
| HomeFeature | 홈: 계좌 목록 | Domain, DesignSystem |
| TransferFeature | 송금: 받는 사람 → 금액 → 확인 → 결과 | Domain, DesignSystem |
| DataKit | 가짜 서버(URLProtocol), BankingRepository 구현 | Domain |
| Domain | 모델, BankingRepository 프로토콜, TransferRule | 없음 |
| DesignSystem | 색·글꼴·간격, PrimaryButton, formatWon | 없음 |

- Feature끼리 서로 import 금지. 연결은 App에서 한다.
- Domain은 SwiftUI·네트워크 import 금지.
- 화면 로직은 `@Observable` 모델에 둔다. 뷰는 표시만 한다.
- 모듈 추가: `Project.swift`의 `modules` 목록에 한 줄 추가 + `Modules/<이름>/Sources`, `Modules/<이름>/Tests` 생성.

## 명령 (저장소 루트에서)
xcode-select가 Command Line Tools를 가리키면 먼저 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```bash
brew install --cask tuist   # 최초 1회. 검증 버전 4.216.0
tuist generate --no-open   # Project.swift 수정 후, 새 worktree에서 매번
xcrun simctl list devices | grep -q "PayLab-$(git branch --show-current)" || xcrun simctl create "PayLab-$(git branch --show-current)" com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro   # 세션 시작 시 1회
xcodebuild -workspace PayLab.xcworkspace -scheme PayLab -destination "platform=iOS Simulator,name=PayLab-$(git branch --show-current)" -derivedDataPath .build/DerivedData build
xcrun simctl boot "PayLab-$(git branch --show-current)" 2>/dev/null   # 테스트 전 부팅 (꺼져 있으면 첫 테스트가 실패할 수 있음)
xcodebuild -workspace PayLab.xcworkspace -scheme PayLab -destination "platform=iOS Simulator,name=PayLab-$(git branch --show-current)" -derivedDataPath .build/DerivedData test
xcrun simctl install "PayLab-$(git branch --show-current)" .build/DerivedData/Build/Products/Debug-iphonesimulator/PayLab.app
xcrun simctl launch --terminate-running-process "PayLab-$(git branch --show-current)" com.example.paylab                   # 일반 실행
xcrun simctl launch --terminate-running-process "PayLab-$(git branch --show-current)" com.example.paylab --fail-transfer   # 송금 실패 주입
```

세션마다 브랜치 이름의 시뮬레이터(`PayLab-<브랜치>`)를 따로 쓴다. 병렬 세션이 서로의 앱과 테스트를 죽이지 않게 하기 위해서다.

테스트는 Swift Testing(`import Testing`)이다. xcodebuild는 XCTest 번들마다 "Executed 0 tests"를 찍으므로, 실제 개수는 Swift Testing 줄에서 읽는다. 현재 6개.

## 디버깅
버그 원인은 Claude가 명령줄로 찾는다. 로그 → 도구 → 코드 순서. 설계: docs/superpowers/specs/2026-11-10-debugging-design.md

### 로그 체계
`os.Logger`, subsystem `com.example.paylab`. 보간 값은 모두 `.public`이라 가려지지 않는다.

| 카테고리 | 남기는 줄 |
|---|---|
| `app` | `launch failTransfers=<bool>` |
| `network` | `request <메서드> /<경로>` · `response <상태> <메서드> /<경로> <ms>ms <바이트>B` · `body <메서드> /<경로> <원문>`(DEBUG 빌드만) · `decode failed <타입> <메서드> /<경로>: <종류>(<타입·키>) at <필드 경로>: <설명>` + 원문 `body` (예: `typeMismatch(Int) at [0].balance`, `keyNotFound(transferID) at <root>`) · `transport failed …` |
| `home` | `load start` · `load ok accounts=<n>` · `load failed keep=<n>: <오류>` |
| `transfer` | `recipients start/ok count=<n>/failed` · `select recipient=<id>` · `confirm amount=<n>` / `confirm blocked amountText=… amount=… balance=…` · `submit start/ok/failed` / `submit ignored recipient=… amount=…` |

- 레벨: debug = 요청·원문·시작, info = 성공, error = 실패·`blocked`·`ignored`·비 2xx 응답.
- `body` 원문 길이가 `response` 줄의 바이트 수보다 짧으면 로그에서 잘린 것이다.
- 로그가 없는 곳: 뷰(SwiftUI `body`), `FakeServer` 내부. 이쪽 문제는 "모델 로그 정상 + 화면 이상"으로 드러난다.

### 준비 (같은 셸에서)
```bash
SIM="PayLab-$(git branch --show-current)"
xcrun simctl bootstatus "$SIM" -b   # 부팅 완료까지 대기. 부팅 직후 launch는 "No such process"로 실패할 수 있다
xcrun simctl spawn "$SIM" log config --subsystem com.example.paylab --mode "level:debug,persist:debug"   # 시뮬레이터마다 1회. 안 하면 log show에서 debug 줄이 빠진다
PID=$(xcrun simctl spawn "$SIM" launchctl list | awk '/com.example.paylab/ {print $1}')   # 이 시뮬레이터의 PayLab PID. pgrep은 다른 세션 시뮬레이터의 PayLab까지 잡는다
UDID=$(xcrun simctl list devices | grep -F "$SIM (" | grep -oE '[0-9A-F-]{36}')            # 이 시뮬레이터 UDID. 크래시 리포트를 고를 때 쓴다
```

### 로그 읽기와 재현
```bash
xcrun simctl spawn "$SIM" log stream --level debug --style compact --predicate 'subsystem == "com.example.paylab"' > <scratchpad>/app.log   # 백그라운드로 띄우고 재현한 뒤 파일을 읽는다
xcrun simctl spawn "$SIM" log show --last 5m --info --debug --style compact --predicate 'subsystem == "com.example.paylab"'          # 이미 지나간 일 조회
xcrun simctl io "$SIM" screenshot <scratchpad>/screen.png                                                                              # 화면 확인
```
- `log stream` 첫 줄의 `getpwuid_r did not find a match for uid 501`은 잡음이다.
- 화면 조작은 iOS 시뮬레이터 도구(`mcp__Claude_Code_iOS_Simulator__control`)의 `tap`·`screenshot`. 좌표는 포인트(402×874).
- 금액 입력: `text` 동작은 붙여넣기라 막힌다. 금액 칸을 탭해 숫자 키패드를 띄운 뒤 키를 하나씩 탭한다.
- 스크린샷은 탭보다 늦게 갱신될 수 있다. 화면이 안 바뀐 것 같으면 한 번 더 찍거나, 로그(`select`, `confirm` 등)로 탭이 들어갔는지 본다.

### 유형별 절차
**디코딩 불일치** (목록이 비었다, 화면이 안 넘어간다)
- `grep "decode failed"` → 타입·필드 경로·이유. 바로 뒤 `body` 줄 원문을 `Modules/Domain/Sources/Models.swift`와 비교한다.

**무반응·렌더링 실패** — 해당 동작의 마지막 로그로 구분한다.

| 로그 | 뜻 | 다음에 볼 곳 |
|---|---|---|
| 해당 동작의 로그가 아예 없음 | 모델 메서드가 불리지 않음 | 그 화면 뷰의 버튼·탭 연결 (`Modules/*/Sources/*View.swift`) |
| 같은 버튼이 위치에 따라 로그가 찍히기도, 안 찍히기도 함 | 탭 영역이 보이는 모양보다 좁음 | 버튼 label 밖에 붙은 `.background`·`.padding`·`.frame`, `.contentShape` 누락. 탭 하나마다 로그를 확인해 반응하는 영역을 그려 본다 |
| `confirm blocked` / `submit ignored` | guard에 막힘 | 로그에 찍힌 값과 조건 (`TransferRule`, `canProceed`) |
| `request`만 있고 `response`가 없음 | 응답이 오지 않음 | 가짜 서버 지연·`FakeServerURLProtocol` |
| 비 2xx `response` / `decode failed` / `… failed` | 실패가 화면에서 삼켜짐 | 그 오류 |
| `… ok`인데 스크린샷에 없음 | 모델은 정상, 뷰가 못 그림 | 그 화면 뷰 코드 |
| 로그가 중간에 끊기고 앱이 사라짐 (예: `response 200` 뒤 `submit ok/failed` 없음) | 크래시 | 아래 "메인 스레드 위반·크래시" 절차 |

**멈춤** (화면이 굳었다)
- 멈춘 상태에서 `sample $PID 3 -file <scratchpad>/sample.txt` → `grep "PayLab.debug.dylib" <scratchpad>/sample.txt`로 앱 코드 프레임을 찾는다.
- `com.apple.main-thread` 스레드가 앱 프레임에서 오래 머물면 그 함수가 원인이다. 정상 대기는 `mach_msg2_trap` / `__CFRunLoopServiceMachPort`다.
- 앱 프레임 바로 아래도 본다: `grep -A4 "PayLab.debug.dylib" <scratchpad>/sample.txt`.
  - 아래가 계산 함수면: 메인 스레드에서 무거운 일을 한다.
  - 아래가 `semaphore_wait_trap` · `_dispatch_sync_f_slow` · `__psynch_mutexwait` 같은 대기이고 CPU가 0%면: 교착이다. 메인 스레드가 기다리는 일이 다른 스레드에서 돌고 있는지 확인한다. 그 일이 MainActor·메인 큐에서 돌아야 하면 영원히 풀리지 않는다.
  - CPU 확인: `ps -o pid,%cpu,stat -p $PID`.

**메모리 누수** (반복할수록 메모리가 는다)
- `SIMCTL_CHILD_MallocStackLogging=1 xcrun simctl launch --terminate-running-process "$SIM" com.example.paylab`로 실행하고 PID를 다시 구한다.
- `heap $PID | grep PayLab.debug.dylib` → 앱 타입별 인스턴스 수. 의심 동작(예: 송금 창 열고 닫기)을 N번 반복한 전후로 비교한다. 계속 느는 타입이 후보다.
- `leaks $PID | sed -n '/leaks Report/,/Binary Images/p'` → 누수 객체, 순환 참조, 할당 스택.
- 순환 트리 읽는 법:
  - `__strong _onFinish.context`: `@Observable` 속성(`_` 접두)이 클로저를 강하게 잡는다.
  - `Closure context`: 클로저가 캡처한 값 묶음.
  - `StoredLocation<T>`: `@State` 저장소. 이게 보이면 클로저가 뷰 구조체 `self`를 캡처했다는 뜻이다.
  - `PresentationMode` / `LocationBox<…Binding…>`: 시트의 `dismiss`.
- 클로저가 어디서 만들어졌는지: 순환 트리의 `Closure context` 주소로 할당 스택을 본다. 출력의 마지막 앱 프레임이 그 클로저를 만든 함수다(예: `closure #2 in TransferFlowView.body.getter`).
  `malloc_history $PID <주소> | grep "^ALLOC" | tr '|' '\n' | grep PayLab.debug.dylib | tail -3`
- 기준은 `heap` 개수다. `leaks`는 보수적 스캔이라 일부 인스턴스를 누수로 세지 않을 수 있다.
- 잡음:
  - 앱 시작 직후부터 있는 `ROOT LEAK: <non-object …> [32]` 1개(NO STACK).
  - `DYLD_SHARED_REGION=avoid not supported for simulator`, `Process … is not debuggable` 경고. 결과에는 영향이 없다.

**메인 스레드 위반·크래시** (앱이 꺼졌다)
- `python3 -I scripts/crash-summary.py --device "$UDID"` → 이 시뮬레이터의 가장 최근 `~/Library/Logs/DiagnosticReports/PayLab-*.ips`에서 예외, 종료 이유, pid, 앱 메시지(Swift fatal error 등), 크래시 스레드 프레임을 보여 준다.
  - `--device`를 빼면 다른 세션 시뮬레이터의 리포트를 고를 수 있다.
  - 출력의 `time`이 재현 시각과 맞는지 먼저 본다.
- 크래시 직전 시스템 메시지(`BUG IN CLIENT OF LIBDISPATCH …`, 런타임 assert 등)는 앱 subsystem 로그에 없다. 리포트의 pid로 따로 조회한다:
  `xcrun simctl spawn "$SIM" log show --last 10m --style compact --predicate 'processID == <pid>' | grep -E "BUG IN CLIENT|Fatal error|Assertion failed"`
- `EXC_BREAKPOINT` + `_dispatch_assert_queue_fail` + 크래시 스레드 queue가 `…cooperative`(메인 아님)면: 메인 전용 코드(`MainActor.assumeIsolated`, `@MainActor` 메서드)가 백그라운드에서 불렸다. 그 프레임 바로 위 앱 함수가 원인이고, 그 아래 앱 함수가 백그라운드에서 부른 쪽이다.
- 재현할 때 Main Thread Checker를 켜면, 메인 스레드 전용 API를 다른 스레드에서 부를 때 바로 크래시하고 리포트가 남는다:
  `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=/Applications/Xcode.app/Contents/Developer/usr/lib/libMainThreadChecker.dylib SIMCTL_CHILD_MTC_CRASH_ON_REPORT=1 xcrun simctl launch --terminate-running-process "$SIM" com.example.paylab`
- 데이터 경쟁은 Thread Sanitizer 빌드로 본다. 보고는 stderr로 나오므로 `--console-pty`로 실행해 파일로 받는다. 끝나면 일반 빌드를 다시 설치한다.
  ```bash
  xcodebuild -workspace PayLab.xcworkspace -scheme PayLab -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath .build/DerivedData-tsan -enableThreadSanitizer YES build
  xcrun simctl install "$SIM" .build/DerivedData-tsan/Build/Products/Debug-iphonesimulator/PayLab.app
  xcrun simctl launch --console-pty --terminate-running-process "$SIM" com.example.paylab > <scratchpad>/tsan.txt 2>&1   # 백그라운드로
  ```

## 금지
- `*.xcodeproj`, `*.xcworkspace`, `Derived/`, `.build/` 커밋 금지
- 외부 라이브러리 추가는 해당 주제 세션에서 사용자 확인 후
