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
xcrun simctl launch --terminate-running-process "PayLab-$(git branch --show-current)" com.example.paylab --fail-transfer   # 처리 전 500 주입 (로딩 → 송금 실패 · 보내지 않았어요). 다른 실패 주입은 아래 "트랜잭션"
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
| `hang` | `hang id=<id> duration=<ms>ms frames=<n>` · `hang frame id=<id> #<i> <이미지> 0x<주소> base=0x<로드 주소> <심볼\|?>` (Debug 빌드, 메인 스레드가 250ms 이상 막힐 때 한 번) |
| `history` | `load start account=<id>` · `load ok account=<id> count=<n> sections=<m>` · `load failed account=<id>: <오류>` |
| `transfer` | `recipients start/ok count=<n>/failed` · `select recipient=<id>` · `confirm amount=<n>` / `confirm blocked amountText=… amount=… balance=…` · `submit start key=<키> …` · `submit ok` / `submit ok unreadable` / `submit rejected status=<n>` / `submit retry attempt=<n> after=<ms>ms: <오류>` / `submit check after attempts=<n>` · `submit check start/ok/notFound` / `submit check ok unreadable` / `submit unknown key=…: <오류>` · `submit ignored inFlight/done` / `submit ignored recipient=… amount=… key=…` · `confirm ignored inFlight/done` |

- 레벨: debug = 요청·원문·시작, info = 성공, error = 실패·`blocked`·`ignored`·비 2xx 응답·`hang`.
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
| 비 2xx `response` / `decode failed` / `… failed` | 실패가 화면에서 삼켜짐 | 그 오류. 예외: `POST /transfers`·`GET /transfers/<키>`의 `decode failed`는 의도대로 "보냈어요"(`submit ok unreadable` / `submit check ok unreadable`). 아래 "트랜잭션" |
| `… ok`인데 스크린샷에 없음 | 모델은 정상, 뷰가 못 그림 | 그 화면 뷰 코드 |
| 로그가 중간에 끊기고 앱이 사라짐 (예: `response 200` 뒤 `submit ok` 없음) | 크래시 | 아래 "메인 스레드 위반·크래시" 절차 |

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

## CI (GitHub Actions)
- 원격: https://github.com/BEYun/PayLab (공개). 설정: `.github/workflows/ci.yml`.
- 실행 시점: `main` push, PR 열기·갱신.
- 환경: GitHub 러너 `xcode-27`(미리보기), Xcode 27.2, `iPhone 18 Pro` / iOS 27.0. `PayLab-<브랜치>` 시뮬레이터는 로컬 전용.
- 단계: Tuist 설치(버전·체크섬 고정) → `tuist generate` → 시뮬레이터 부팅 → `build-for-testing` → `test-without-building`.
- Claude(`anthropics/claude-code-action@v1`): PR을 열거나 다시 열면 `claude-review` 잡이 리뷰 코멘트, PR 빌드·테스트가 실패하면 `claude-ci-failure` 잡이 원인 코멘트. 소유자 PR만 실행. 코드는 고치지 않는다.
- Claude 인증: 저장소 Secret `CLAUDE_CODE_OAUTH_TOKEN`(`claude setup-token`으로 발급, 사용자가 직접 등록). 코멘트는 `github-actions[bot]` 이름.
- Tuist 버전 변경: 워크플로의 `TUIST_VERSION`과 `TUIST_SHA256`(릴리스의 `SHASUMS256.txt`)을 함께 바꾸고 로컬 Tuist도 맞춘다.
- 공개 저장소다. 커밋 작성자는 GitHub noreply 메일(저장소 git 설정). 커밋 전에 키·토큰·개인 경로가 없는지 확인한다.

```bash
gh pr checks                       # 현재 브랜치 PR의 CI 결과
gh run list --limit 5              # 최근 실행
gh run view <run-id> --log-failed  # 실패한 단계 로그만
```

## 테스트

설계: docs/superpowers/specs/2026-11-10-testing-design.md

### 작업 흐름 (모든 작업)
기능 명세서 → 설계 → 코드 + 테스트 코드 → 단위 테스트 → 통합 테스트 → 시뮬레이터 테스트(UI 테스트 + Claude 확인) → 커밋

- 명세·설계는 `docs/superpowers/specs/`, 구현 계획은 `docs/superpowers/plans/`.
- 새 코드에는 같은 작업 안에서 테스트를 함께 쓴다. 버그 수정은 재현 테스트를 먼저 쓴다.
- 이미 있는 코드에 테스트를 붙이면, 대상 코드를 잠깐 망가뜨려 테스트가 실패하는지 확인하고 되돌린다.

### 단계별 명령 (저장소 루트에서)
```bash
xcodebuild -workspace PayLab.xcworkspace -scheme PayLab -destination "platform=iOS Simulator,name=PayLab-$(git branch --show-current)" -derivedDataPath .build/DerivedData test -only-testing:DomainTests   # 단위: 모듈 하나 (타깃 이름 교체)
xcodebuild -workspace PayLab.xcworkspace -scheme PayLab -destination "platform=iOS Simulator,name=PayLab-$(git branch --show-current)" -derivedDataPath .build/DerivedData test   # 단위 + 통합 (공용 PayLab 스킴, CI도 이것만)
xcodebuild -workspace PayLab.xcworkspace -scheme PayLabUITests -destination "platform=iOS Simulator,name=PayLab-$(git branch --show-current)" -derivedDataPath .build/DerivedData test   # UI
scripts/test-all.sh   # 전체: 생성 → 시뮬레이터 → 단위·통합(커버리지) → UI(커버리지) → hook 테스트 → perf-report 테스트 → (끝에서) 성능 수집·판정. 이번 변경의 성능 문제가 있으면 실패. 마지막 줄 ALL TESTS PASSED
```

### 테스트 위치
| 단계 | 위치 | 대상 |
|---|---|---|
| 단위 | `Modules/<모듈>/Tests` | 순수 로직, `@Observable` 모델(타깃별 `StubBankingRepository` 주입), `FakeServer.handle` 직접 호출 |
| 통합 | `DataKitTests`의 `RemoteBankingRepositoryTests`, `PayLabTests` | 모델 → `RemoteBankingRepository` → `URLSession` → 가짜 서버 |
| UI | `Modules/App/UITests` (스킴 `PayLabUITests`) | 앱을 띄워 송금 성공·실패 흐름을 누름 |
| Claude 확인 | 코드 없음 | 앱 설치·실행 후 iOS Simulator 제어 도구로 탭, 스크린샷 |

### 규칙
- 단위·통합은 Swift Testing, UI 테스트만 XCTest.
- `FakeBackend.makeSession`(또는 `AppEnvironment.makeRepository`)을 부르는 테스트는 그 타깃의 `@Suite(.serialized)`에만 둔다. 등록이 프로세스 전역이라서다. 테스트 번들끼리는 프로세스가 달라 간섭하지 않는다.
- 테스트의 가짜 서버는 `FakeServer(latency: .zero)`. 각 테스트가 자기 서버를 새로 만든다.
- UI 테스트: 고정 sleep 금지, `waitForExistence`. 요소는 화면 텍스트로 찾고, 안 잡힐 때만 `.accessibilityIdentifier`를 단다.
- Claude 확인: 작업 완료 보고에 스크린샷(`.build/screens/`)을 붙인다. 제어 도구의 텍스트 입력은 붙여넣기라 동작하지 않으니 숫자 키패드를 탭한다.
- 제품 코드 동작이 이상해도 테스트 작업에서 고치지 않는다. 현재 동작을 테스트로 고정하고 기록한다(트랜잭션 인계: 위 설계 문서 부록 A).

### 커밋 hook
- `.claude/settings.json`의 `PreToolUse` hook: Claude가 `git commit`이 든 Bash 명령을 실행하면 먼저 `scripts/test-all.sh`를 돌린다. 실패하면 커밋을 막고 실패 요약을 보여 준다. 로그 `.build/hook-test.log`.
- 막히면 테스트나 코드를 고친다. hook 설정을 끄거나 우회하지 않는다.
- `PAYLAB_TEST_CMD` 환경 변수는 hook 자체 테스트(`scripts/test-hook.sh`) 전용이다.
- 사람이 터미널에서 직접 하는 커밋은 막지 않는다.
- `"onFailure": "block"`(hook이 시간 초과·실행 실패해도 커밋을 막음)은 Claude Code 2.1.295 이상에서 동작한다.
- 세션 도중 처음 생긴 hook은 그 세션에 반영되지 않았다(2026-11-10 확인). 새 세션에서 실제로 커밋이 막히는지는 아직 확인하지 않았다.

### 커버리지 (측정만, 차단 없음)
```bash
xcrun xccov view --report --only-targets .build/TestResults/PayLab.xcresult   # scripts/test-all.sh 실행 후
```

기준선 (2026-11-10, PayLab 스킴 단위·통합, UI 테스트 제외). 2026-11-12 열은 이 브랜치(거래 내역·hang 감시자)가 바꾼 모듈만 다시 쟀다:

| 모듈 | 커버리지 | 2026-11-12 | 메모 |
|---|---|---|---|
| Domain | 100% (26/26) | 100% (32/32) | |
| DataKit | 97.33% (146/150) | 94.25% (295/313) | |
| HomeFeature | 99.23% (129/130) | 66.12% (203/307) | 테스트 호스트 앱이 홈 화면을 그려 뷰 코드까지 잡힘. `HomeModel` 100% |
| TransferFeature | 15.54% (39/251) | | 뷰 코드 0%. `TransferModel` 100% |
| DesignSystem | 14.29% (4/28) | | `formatWon` 100%, `PrimaryButton` 0% |
| PayLab (App) | 74.29% (26/35) | 89.19% (132/148) | `AppEnvironment` 100% |

- 낮은 수치는 대부분 SwiftUI 뷰다. 로직 파일(`*Model`, `RemoteBankingRepository`, `AppEnvironment`, `formatWon`)이 100%에서 떨어지면 빠진 테스트를 찾는다.

### 테스트 개수 (2026-11-11)
- Swift Testing 59개(매개변수 테스트는 1개로 셈) + UI 테스트 3개 + hook 테스트 14개.
- 위 "현재 6개"는 기반 단계 기준이다.

### 테스트 개수 (2026-11-12)
- Swift Testing 72개(`test-all.sh` 출력의 `Test run with N tests` 합) + UI 테스트 4개(거래 내역 추가) + hook 테스트 14개 + perf-report 테스트 81개(`scripts/test_perf_report.py`, `unittest`, 2026-11-12 최종 리뷰 반영 후 실행 결과 `Ran 81 tests`).

## 트랜잭션 (송금 정합성)

설계: docs/superpowers/specs/2026-11-11-transaction-design.md

목표: 돈은 정확히 한 번만 빠지고, 화면은 서버 결과와 어긋나지 않는다.

### 송금 키
- 송금 한 건 = 키 하나. `TransferModel.proceedToConfirm()`을 통과할 때마다 새 UUID(`idempotencyKey`).
- HTTP 헤더 `Idempotency-Key`로 보낸다. 자동 재시도와 자동 조회는 같은 키를 쓴다. 송금이 시작되면 `proceedToConfirm()`은 무시돼 키가 바뀌지 않는다.
- 가짜 서버 `POST /transfers` 판정 순서: 실패 주입 500 → 키 없음 400 → 본문 400 → **같은 키**(같은 본문: 200 + 저장된 영수증, 잔액 그대로 / 다른 본문: 422) → 계좌·받는 사람 404 → 금액 400 → 처리.
  - 같은 키 확인이 금액 검사보다 먼저다. 처리 뒤 잔액이 줄어든 상태의 재요청에도 저장된 영수증을 준다(`FakeServerTests.replayBeatsBalanceCheck`).
- `GET /transfers/<키>`: 처리된 송금이면 200 + 영수증, 없으면 404. `findTransfer(idempotencyKey:)`는 404를 `nil`로 돌려준다.

### 결과 분류 (`TransferModel.submit`)
| 응답 | 서버가 처리했나 | 재시도 | 화면 (`Outcome`) |
|---|---|---|---|
| 2xx | 했음 | 없음 | 보냈어요 + 남은 잔액 (`.success(receipt)`) |
| 2xx + 디코딩 실패 | 했음 | 없음 | 보냈어요, 잔액 줄 없음 (`.success(nil)`) |
| 4xx | 안 함 | 없음 | 송금 실패 + 이유 (`.failure(.rejected)`) |
| 5xx, 전송 오류, 그 밖 | 모름 | 같은 키로 2회 (0.5초, 1초) | 키로 자동 조회 1번 (아래) |

- 자동 조회는 조회만 한다(송금을 새로 만들지 않음). 찾음 → 보냈어요, 404 → 송금 실패 "보내지 않았어요"(`.failure(.notSent)`), 조회 실패 → "결과를 확인하지 못했어요"(`.unknown`, 버튼은 확인 하나).
- 흐름: 보내기 → 로딩("보내는 중이에요", 재시도·조회가 끝날 때까지) → 결과. 사용자가 중간에 누를 것은 없다(사용자 피드백으로 개정, 설계 "개정 이력").
- 송금 중(`isSubmitting`): "보내기" 비활성, 뒤로 가기 숨김, 시트 끌어내리기 막음. 결과가 나온 뒤의 `submit()`도 무시한다.
- `.unknown`은 지금 실패 주입으로 재현되지 않는다(조회 경로는 주입 대상이 아님). 단위 테스트로만 고정. 앱을 껐다 켜면 이 송금은 잊힌다(로컬 저장소 없음, 범위 밖).

### 실패 주입 (실행 인자)
| 인자 | 서버 동작 | 기대 화면 |
|---|---|---|
| `--fail-transfer` | 처리 전 500, 매번 | 로딩 → 송금 실패 "보내지 않았어요" (자동 조회 404). 잔액 그대로 |
| `--drop-transfer-response-once` | 처리 뒤 첫 200 응답만 연결 끊김 | 재시도 1번 → 보냈어요. 잔액 한 번 차감 |
| `--drop-transfer-response` | 처리 뒤 200 응답을 매번 연결 끊김 | 로딩 → 보냈어요 (자동 조회가 찾음). 잔액 한 번 차감 |
| `--garble-transfer-response` | 처리 뒤 200 + 읽을 수 없는 본문 | 보냈어요 (잔액 줄 없음). 잔액 한 번 차감 |

- 시작 로그: `launch failTransfers=<bool>`, `launch transferFault=<dropResponseOnce|dropResponseAlways|garbleResponse|none>`.
- 실행: `xcrun simctl launch --terminate-running-process "PayLab-$(git branch --show-current)" com.example.paylab --drop-transfer-response`
- 재현 확인은 로그로 한다: `request POST /transfers` 줄 수(원 요청 + 재시도), `submit retry`, `submit check …`, `submit unknown`. 홈 잔액은 `body GET /accounts` 줄.

### 테스트 위치
- 서버 계약: `FakeServerTests`(키·재요청·422·조회·실패 주입), `RemoteBankingRepositoryTests`(헤더 전송, 404 → nil, `URLError`·`DecodingError`).
- 모델: `TransferModelTests` — 가짜 저장소 응답은 `StubBankingRepository.Reply`, 재시도 대기는 `retryDelays: [.zero, .zero]`. 연타·송금 중 재현은 `holdFirstTransfer` + `waitUntilHeld()`/`release()`.
- 통합: `AppIntegrationTests`(실패 주입 4가지 각각 화면 상태와 홈 잔액). UI: `TransferFlowUITests`(실패 → 로딩 → 보내지 않았어요, 응답 유실 → 로딩 → 보냈어요).

## 성능 (hang·크래시·느린 빌드 자동 수집)

설계: docs/superpowers/specs/2026-11-11-performance-design.md

목표: 테스트·빌드 중 생긴 성능 문제를 자동으로 찾아 기록한다. 문제 하나 = GitHub 이슈 하나. 고치는 건 사람이다.
- **기존 문제**(이번 변경과 무관) → 공개 이슈.
- **이번 변경의 문제** → 이슈 없음. 로컬은 커밋 차단, PR은 코멘트. 그 작업 안에서 고친다.

### 문제 종류와 기준
| 종류 | 감지 | 비정상 기준 | 어디서 |
|---|---|---|---|
| `crash` | 시뮬레이터 `PayLab-*.ips` (UDID·시작 시각으로 거름) | PayLab 프로세스 크래시 | 로컬, CI |
| `hang` | 앱 안 `HangMonitor`(`Modules/App/Sources/HangMonitor.swift`, Debug 전용) → `hang` 로그 | 메인 스레드 **250ms 이상** 응답 없음 | 로컬, CI |
| `slow-build` 느린 함수 | Debug 빌드 플래그 `-warn-long-function-bodies=100` `-warn-long-expression-type-checking=100` | 타입 검사 **100ms 초과** | 로컬(변경 파일만), CI |
| `slow-build` 컴파일 시간 | CI `-showBuildTimingSummary` | 우리 코드 컴파일이 main 최근 5회 중앙값보다 **30% 이상, 10초 이상** 늘어남. 기준 5회 미만이면 판정 안 함 | CI만 |

- hang `duration`은 하한이다. 실제보다 최대 약 50ms 짧게 찍힌다.
- UI 테스트는 앱을 띄울 때마다 약 1.3초 시스템 hang을 만든다. 원인은 UIKit 접근성 초기화로 **추정**한다(잡힌 우리 코드 프레임은 진입점뿐이라 확인하지 못함). 스택에 우리 코드가 진입점뿐인 hang은 무시하고 `report.json`의 `ignored_hangs`에만 센다(`test-all.sh` 한 번에 보통 4).
- 디버거로 멈춘 시간(중단점)도 감시자에게는 hang으로 보인다. 디버깅한 시간대에는 `collect`를 돌리지 않는다.
- "우리 코드" = 기호화한 파일이 저장소 안인 프레임. 컴파일러가 만든 진입점(`main`, `PayLabApp.$main()`)은 뺀다.

### 판정: 이번 변경 vs 기존
- 위치 파일: crash·hang은 스택의 **모든** 우리 코드 프레임 파일, 느린 함수는 경고가 가리킨 파일. 컴파일 시간은 파일 없음(PR = 이번 변경, main = 기존).
- 위치 파일 중 하나라도 변경 파일이면 "이번 변경", 아니면 "기존".
- 스택에 우리 코드가 없는 크래시는 컴파일 시간처럼: 로컬·PR = "이번 변경"(이슈 없음), main = "기존". 서명은 가장 안쪽의 기호화된 프레임 함수(없으면 기호)라 시스템 코드만 있는 크래시끼리 섞이지 않는다.
- 변경 파일: 로컬 = `origin/main` merge-base 이후 커밋 + 스테이징 + 미스테이징 + 새 파일(`git fetch` 안 함). PR = `--changed-from HEAD^1`. main push = 판정 없음(모두 기존).
- 변경 파일을 알 수 없으면 전부 "이번 변경"으로 본다.
- 로컬은 변경된 Swift 파일의 느린 함수만 본다. `test-all.sh`가 빌드 전에 그 파일을 `touch`해 다시 컴파일시킨다. 기존 느린 함수는 CI가 잡는다.
- 한계: 스택에 남지 않는 방식(예: 데이터 양만 늘림)은 "기존"으로 잘못 판정된다. 이슈의 브랜치·커밋을 보고 닫는다.

### 이슈 (공개)
- 라벨: `perf-auto` + `crash`/`hang`/`slow-build` 중 하나. 없으면 만든다.
- 제목: `[hang] HistoryModel.makeSections(_:) 714ms`. 본문: 수치, 처음 발견한 곳(로컬/CI, 브랜치, 커밋, CI 실행), 재현 단서(직전 앱 로그), 우리 코드 스택(파일:줄), 숨은 서명, 발생 기록.
- 서명 `<!-- perf-signature: … -->`: crash = 예외 종류 + 가장 안쪽 우리 함수(없으면 가장 안쪽 기호화된 프레임의 함수·기호), hang = 가장 안쪽 우리 함수, 느린 함수 = 파일 + 함수(줄 번호 없음), 컴파일 시간 = 고정 하나.
- 같은 서명의 **열린** 이슈가 있으면 새로 만들지 않고 본문의 발생 기록(`<!-- perf-occurrences:start/end -->`: 횟수, 마지막 발견, 최근 발견한 곳)만 고친다. 코멘트는 달지 않는다.
- 같은 서명의 **닫힌** 이슈만 있으면: CI는 이전 이슈를 링크한 새 이슈를 만들고, 로컬은 출력만 한다(오래된 브랜치가 이미 고친 문제로 가짜 재발 이슈를 만들지 않게).
  - 예외: 가장 최근 닫힌 이슈가 "계획 없음"(`stateReason` `NOT_PLANNED`)이면 로컬·PR·main 모두 출력만 한다(`[기존 → 닫힌 이슈 #n (계획 없음), 기록만]`). 거짓 양성을 끄는 방법이다.
- 올리기 전 홈 경로(`~`), UDID, 컴퓨터 이름, 메일, 토큰 모양 문자열을 지운다. 이슈를 만든 뒤 `gh issue view <번호> --json body`로 본문을 읽어 확인한다.
- 브랜치 이름은 본문·발생 기록에서 코드(`` ` ``)로 감싼다(`@` 멘션 방지).
- `gh` 호출 한 번은 60초 제한이다. 실패·시간 초과 시 경고만 하고 넘어가며, 올리지 못한 이슈는 `.build/perf/pending-issues.json`에 남는다.

### 로컬
`scripts/test-all.sh`는 끝에서(테스트 성공·실패 무관) `collect` → `report --where local`을 돈다. 이번 변경의 hang·느린 함수가 있으면 `실패: 이번 변경의 성능 문제`로 끝나 커밋이 막힌다.
- 읽는 곳: 출력의 `[이번 변경] [hang] <함수> <ms> <파일:줄>` 줄, `.build/perf/report.json`(`problems`, `ignored_hangs`, `warnings`).
- `report` 종료 코드: 0 정상(기존 문제만 있거나 없음), 1 이번 변경 있음, 2 사용 오류. `collect`는 시뮬레이터 로그·products 디렉터리를 못 읽거나, hang·크래시 프레임의 이미지 기호화(`dsymutil`·`atos`)가 실패·시간 초과(120초)하면 2. 기호화 실패를 경고로 넘기면 우리 코드 hang이 "무시"로 보이기 때문이다.
- 기존 문제는 자동으로 이슈가 된다(`gh` 필요). 차단하지 않는다.
- 막히면 그 문제를 고친다. 이슈로 돌리려고 우회하지 않는다.

시뮬레이터 확인(Claude) 뒤에는 확인을 시작한 시각부터의 hang·크래시를 같은 스크립트로 처리한다:
```bash
SIM="PayLab-$(git branch --show-current)"; UDID=$(xcrun simctl list devices | grep -F "$SIM (" | grep -oE '[0-9A-F-]{36}' | head -n 1)
START=$(date '+%Y-%m-%d %H:%M:%S')   # 확인을 시작할 때 기록
# …앱 설치·실행·탭…
python3 -I scripts/perf-report.py collect --since "$START" --device "$UDID" --products .build/DerivedData/Build/Products/Debug-iphonesimulator --out .build/perf/report.json
python3 -I scripts/perf-report.py report --input .build/perf/report.json --where local   # 이번 변경이면 [이번 변경] 줄 + 종료 1
```
- 기호화는 `.build/DerivedData`의 마지막 빌드 바이너리로 한다. 확인한 앱과 같은 빌드여야 한다. 앱을 실행한 뒤 `collect`까지 다시 빌드하지 않는다. 다시 빌드하면 기호가 엉뚱한 코드를 가리킨다(스크립트는 이것을 알아채지 못한다). `--build-log`를 빼면 느린 함수 경고는 수집하지 않는다.
- `report`에 `--dry-run`을 붙이면 `gh`를 부르지 않고 할 일만 출력한다. `--no-changes`는 변경 파일 없음으로 본다(시연·테스트용).

### CI
- `build-and-test`: `build-for-testing`에 타이밍 요약을 켜고, 테스트 뒤(실패해도) `collect`를 돌려 artifact `perf-report`(`report.json`)를 올린다. 권한은 읽기만.
- `perf-report` 잡(ubuntu, `issues`·`pull-requests` 쓰기): 빌드가 실패해도 돈다. 취소되면 안 돈다. 소유자 PR과 main push에서만 돈다.
  1. `ci-metrics` → `build-metrics.json` (우리 코드 컴파일, 시스템 모듈 준비, 정규화 값, `xcodebuild` 첫 출력까지, 전체 빌드 단계).
  2. 최근 main 실행 최대 5개의 `build-metrics` artifact를 기준으로 내려받는다.
  3. PR → `report --where pr`(이번 변경은 PR 코멘트 하나를 고쳐 씀, 기존은 이슈). main → `report --where main`(전부 이슈).
  4. 측정값 표를 잡 요약(Job Summary)에 쓴다. main이면 `build-metrics`를 artifact로 올린다.
- 현재 PR 보고는 `ci.yml`의 `PERF_PR_DRY_RUN`으로 `--dry-run`이다. 이 줄을 지워야 PR 코멘트·이슈가 실제로 생긴다.
- report.json이 없으면(빌드가 수집 전에 실패) `::warning::`만 낸다.
- 측정값 보기: `gh run view <run-id>`의 요약, `gh run download <run-id> -n perf-report`.

### 이슈를 받았을 때
이슈의 우리 코드 스택(함수, 파일:줄)에서 시작해 `## 디버깅`의 "멈춤"(hang)·"메인 스레드 위반·크래시"(crash) 절차로 원인을 조사한다. 고친 뒤 `scripts/test-all.sh`가 통과하고, PR이 이슈를 닫는다.
