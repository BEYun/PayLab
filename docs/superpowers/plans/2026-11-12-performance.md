# PayLab 성능 이상 자동 기록 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 테스트·빌드 중 생긴 크래시·UI hang·빌드 시간 이상을 자동으로 모아, 이번 변경의 문제는 커밋 차단·PR 코멘트로, 기존 문제는 공개 GitHub 이슈로 정리한다.

**Architecture:** 앱(Debug) 안 hang 감시자가 메인 스레드 스택 주소를 `hang` 로그로 남긴다. 단일 Python 스크립트 `scripts/perf-report.py`가 로그·크래시 리포트·빌드 로그를 모아 기호화(`collect`)하고, 변경 파일과 비교해 판정·보고(`report`)한다. 로컬은 `scripts/test-all.sh`의 마지막 단계, CI는 기존 macOS 잡의 수집 단계 + 쓰기 권한을 가진 ubuntu 보고 잡이다. hang 재료로 홈 → 거래 내역 화면을 넣는다.

**Tech Stack:** Xcode 27.2, Swift 6 언어 모드, SwiftUI, Observation, Swift Testing, XCTest(UI 전용), Tuist 4.216.0, Python 3.9+ 표준 라이브러리, `gh`, GitHub Actions

**Spec:** `docs/superpowers/specs/2026-11-11-performance-design.md`

## Global Constraints

- 외부 라이브러리 추가 금지 (Swift·Python 모두).
- Feature끼리 import 금지. Domain은 SwiftUI·네트워크 import 금지. 화면 로직은 `@Observable` 모델, 뷰는 표시만.
- 단위·통합: Swift Testing. XCTest는 UI 테스트에만. UI 테스트 고정 sleep 금지, `waitForExistence`.
- `FakeBackend.makeSession`·`AppEnvironment.makeRepository`를 부르는 테스트는 그 타깃의 `@Suite(.serialized)`에만. 테스트의 가짜 서버는 `FakeServer(latency: .zero)`.
- `BankingRepository`가 바뀌면 `HomeFeature`·`TransferFeature`의 `StubBankingRepository`를 둘 다 맞춘다.
- 로그: `os.Logger`, subsystem `com.example.paylab`, 보간 값 `.public`. debug = 시작, info = 성공, error = 실패·hang.
- 기준값 (설계 §6.1, §6.4): hang **250ms**, 느린 함수 **100ms**, 컴파일 시간 = 정규화 값이 main 최근 **5회** 중앙값보다 **30%** 이상 + 우리 코드 컴파일 **10초** 이상 증가.
- 이슈 라벨: `perf-auto`(자동 생성 표시) + 종류 `crash` / `hang` / `slow-build`.
- Python: `scripts/perf-report.py` 한 파일, 실행은 `python3 -I`(스크립트 폴더가 import 경로에 없음). 로컬 `python3`는 Xcode의 **3.9.6**, CI ubuntu는 3.12 → 3.9 문법만 (`match`, `X | Y` 타입 표기 금지, `typing.Optional` 사용).
- 화면 문구: 내비게이션 제목 `거래 내역`, 실패 `거래 내역을 불러오지 못했어요`, 금액 `+12,000원` / `-3,500원`(`formatWon` + 부호).
- 공개 저장소: 커밋·이슈·코멘트에 `/Users/<이름>`, 토큰, 메일, UDID, 컴퓨터 이름 금지. 커밋 금지: `*.xcodeproj`, `*.xcworkspace`, `Derived/`, `.build/`.
- 커밋할 때마다 hook이 `scripts/test-all.sh` 전체를 돈다(상한 600초). hook을 끄거나 우회하지 않는다. 각 Task 끝에서 전체가 녹색이어야 한다.
- `CLAUDE.md`: `## 성능` 섹션 신설. 기존 줄은 로그 표(`hang`, `history` 행), 테스트 개수, `test-all.sh` 설명만 고친다.

## Review Focus

1. 병렬 세션의 다른 시뮬레이터 크래시 리포트(같은 폴더) → 이번 시뮬레이터 UDID가 아니면 무시 → Task 3 `test_collect_ignores_other_device_crash`.
2. `gh` 미인증·오프라인에서 Claude 커밋 → 이슈만 못 만들고 커밋은 막지 않음, 보고는 `.build/perf/pending-issues.json`에 남음 → Task 4 `test_local_gh_failure_does_not_block`.
3. 사람이 이슈 본문을 고쳐 발생 기록 표식이 사라짐 → 덧붙일 때 실패하지 않고 표식 블록을 새로 붙임 → Task 4 `test_record_occurrence_without_markers_appends_block`.
4. 빌드가 수집 전에 실패해 CI artifact가 없음 → 보고 잡은 메시지만 남기고 성공 → Task 4 `test_report_missing_input_exits_zero`.
5. 시간대가 다른 크래시 리포트 시각(`+0900`)과 `--since`(로컬 시각) 비교 → 시작 전 리포트는 무시 → Task 3 `test_collect_ignores_crash_before_since`.

## 공통 명령 (저장소 루트, `DEVELOPER_DIR` 설정한 셸)

| 이름 | 명령 | 통과 기준 |
|---|---|---|
| 모듈 테스트 `<T>` | `xcodebuild -workspace PayLab.xcworkspace -scheme PayLab -destination "platform=iOS Simulator,name=PayLab-$(git branch --show-current)" -derivedDataPath .build/DerivedData test -only-testing:<T> 2>&1 \| grep -E "✘\|✔ Test run\|error:\|TEST SUCCEEDED\|TEST FAILED"` | `** TEST SUCCEEDED **` |
| UI 테스트 | `xcodebuild -workspace PayLab.xcworkspace -scheme PayLabUITests -destination "platform=iOS Simulator,name=PayLab-$(git branch --show-current)" -derivedDataPath .build/DerivedData test` | `** TEST SUCCEEDED **` |
| 스크립트 테스트 | `python3 -I scripts/test_perf_report.py` | 마지막 줄 `OK` |
| 전체 | `scripts/test-all.sh` | 마지막 줄 `ALL TESTS PASSED` |

---

### Task 0: 준비

- [ ] **Step 1:** 설계 문서 상태 줄을 `승인 완료 (2026-11-12)`로 바꾼다.
- [ ] **Step 2: Commit** 설계·계획 문서 (hook 전체 테스트).

```bash
git add docs/superpowers/specs/2026-11-11-performance-design.md docs/superpowers/plans/2026-11-12-performance.md
git commit -m "docs: 성능 이상 자동 기록 설계·계획"
```

---

### Task 1: 거래 내역 데이터 (Domain → 가짜 서버 → 저장소)

**Files:**
- Modify: `Modules/Domain/Sources/Models.swift`, `Modules/Domain/Sources/BankingRepository.swift`
- Modify: `Modules/DataKit/Sources/FakeServer.swift`, `Modules/DataKit/Sources/RemoteBankingRepository.swift`
- Modify: `Modules/HomeFeature/Tests/StubBankingRepository.swift`, `Modules/TransferFeature/Tests/StubBankingRepository.swift`
- Test: `Modules/DataKit/Tests/FakeServerTests.swift`, `Modules/DataKit/Tests/RemoteBankingRepositoryTests.swift`

**Interfaces:**
- Produces (Domain):
  ```swift
  public struct Transaction: Identifiable, Hashable, Codable, Sendable {
      public let id: String; public let date: Date; public let title: String
      public let amount: Int   // 원. 입금 +, 출금 -
  }
  // BankingRepository
  func fetchTransactions(accountID: String) async throws -> [Transaction]
  ```
- Produces (DataKit): `GET /accounts/<id>/transactions` → 200 + `[Transaction]`, 모르는 계좌 404. `public static let transactionsPerAccount = 5_000` (Task 6에서 hang이 안 나면 조정). 날짜는 고정 기준 시각에서 거꾸로 만든다(`Date()` 금지, 실행마다 같은 결과). 응답 순서는 날짜순이 **아니게** 섞는다(앱이 정렬해야 한다).

- [ ] **Step 1: 실패 테스트 — `FakeServerTests`**
  - `transactionsRouteIsDeterministic`: acc-main 두 번 요청 → 둘 다 200, 디코딩 결과 `==`, 개수 `FakeServer.transactionsPerAccount`, `Set(ids).count == count`.
  - `transactionsAreNotDateSorted`: 결과가 날짜 내림차순도 오름차순도 아니다.
  - `transactionsUnknownAccountReturns404`: `/accounts/none/transactions` → 404.
- [ ] **Step 2: 실패 테스트 — `RemoteBankingRepositoryTests`** (기존 직렬 Suite): `fetchTransactionsDecodes` → 개수 `FakeServer.transactionsPerAccount`.
- [ ] **Step 3:** 두 `StubBankingRepository`에 `fetchTransactions`를 `Issue.record` + throw로 추가 (HomeFeature 쪽은 Task 6에서 결과 주입으로 바꾼다).
- [ ] **Step 4:** 모듈 테스트 `DataKitTests`. Expected: 컴파일 오류(`Transaction`, `fetchTransactions` 없음).
- [ ] **Step 5: 구현** — 위 Interfaces대로. 거래 내용은 몇 가지 문구(예: `편의점`, `월급`, `카페`, `김하늘`)를 번갈아 쓴다. 생성은 요청마다 해도 된다.
- [ ] **Step 6:** 모듈 테스트 `DataKitTests`, `HomeFeatureTests`, `TransferFeatureTests`. Expected: SUCCEEDED.
- [ ] **Step 7: Commit**

```bash
git add Modules
git commit -m "feat: 계좌 거래 내역 조회 — 가짜 서버 경로와 저장소"
```

---

### Task 2: hang 감시자 (App)

**Files:**
- Create: `Modules/App/Sources/HangMonitor.swift`
- Modify: `Modules/App/Sources/PayLabApp.swift` (Debug에서 시작)
- Test: `Modules/App/Tests/HangMonitorTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct HangFrame: Sendable, Equatable { let address: UInt; let image: String; let imageBase: UInt; let symbol: String? }
  struct HangReport: Sendable, Equatable { let id: Int; let durationMs: Int; let frames: [HangFrame] }  // frames: 가장 안쪽이 먼저, 최대 64
  final class HangMonitor: Sendable {
      init(threshold: Duration = .milliseconds(250), onHang: @escaping @Sendable (HangReport) -> Void)
      @MainActor func start()     // 메인 스레드 mach 포트를 여기서 잡는다
      func stop()
      static func logLines(_ report: HangReport) -> [String]
      static func log(_ report: HangReport)   // logLines를 category "hang", .error로 한 줄씩
  }
  ```
- 로그 줄 형식 (Task 3 파서와의 계약, 그대로):
  - `hang id=<id> duration=<ms>ms frames=<n>`
  - `hang frame id=<id> #<i> <image 파일 이름> 0x<address 16진> base=0x<imageBase 16진> <symbol 또는 ?>`
- 스택: `thread_suspend` → `thread_get_state(ARM_THREAD_STATE64)` → pc, lr, fp 체인 → `thread_resume`. 이미지·심볼은 `dladdr`. `#if arch(arm64)`가 아니면 프레임 0개. hang 한 번에 보고 한 번(시작 때 잡은 스택, 끝날 때 지속 시간).
- `PayLabApp.init()`: `#if DEBUG`에서 앱 전역 감시자(`onHang: HangMonitor.log`)를 만들어 `start()`하고 보관한다.

- [ ] **Step 1: 실패 테스트 — `HangMonitorTests`** (`@MainActor @Suite(.serialized)`. 앱 전역 감시자 250ms에 걸리지 않게 막는 시간은 250ms 미만)
  - 테스트 파일 안 `@inline(never) func blockMainThread(milliseconds: Int)`: 바쁜 대기.
  - `reportsBlockedMainThread`: `HangMonitor(threshold: .milliseconds(50))` → 150ms 막기 → 2초 안에 보고 1건 이상, `durationMs >= 100`, 어떤 프레임의 `symbol`이 `blockMainThread`를 포함. `stop()`.
  - `ignoresShortBlocks`: threshold 200ms, 50ms 막기, 500ms 기다림 → 보고 0건.
  - `logLinesFormat`: `HangReport(id: 3, durationMs: 412, frames: [HangFrame(address: 0x1a2b, image: "PayLab.debug.dylib", imageBase: 0x1000, symbol: "$s4main"), HangFrame(address: 0x10, image: "libsystem_kernel.dylib", imageBase: 0x0, symbol: nil)])` → 정확히 `["hang id=3 duration=412ms frames=2", "hang frame id=3 #0 PayLab.debug.dylib 0x1a2b base=0x1000 $s4main", "hang frame id=3 #1 libsystem_kernel.dylib 0x10 base=0x0 ?"]`.
- [ ] **Step 2:** 모듈 테스트 `PayLabTests`. Expected: 컴파일 오류(`HangMonitor` 없음).
- [ ] **Step 3: 구현** — 위 Interfaces대로. 신호 주기·스레드 종류는 자유(예: 50ms 간격 전용 `Thread`).
- [ ] **Step 4:** 모듈 테스트 `PayLabTests`. Expected: SUCCEEDED. `reportsBlockedMainThread`의 막는 시간을 40ms로 잠깐 줄여 실패하는지 확인하고 되돌린다.
- [ ] **Step 5: 확인** — 앱 설치·실행 후 `log show`(CLAUDE.md "로그 읽기")에 `category == "hang"` 줄이 없다(평소엔 hang 없음).
- [ ] **Step 6: Commit**

```bash
git add Modules/App
git commit -m "feat: Debug 앱 hang 감시자 — 메인 스레드 250ms 이상 막히면 스택을 로그로"
```

---

### Task 3: `perf-report.py collect` — 수집·기호화

**Files:**
- Create: `scripts/perf-report.py`, `scripts/test_perf_report.py`
- Create: `scripts/fixtures/perf/hang.ndjson`, `crash.ips`, `crash-other-device.ips`, `build.log`

**Interfaces:**
- Produces (Python, 3.9):
  - `parse_hang_log(lines: Iterable[str]) -> List[dict]` — `log show --style ndjson` 줄. 결과 `{"pid", "id", "duration_ms", "time", "frames": [Frame], "context": [str]}`. `context` = 같은 pid의 hang 이전 다른 카테고리 `eventMessage` 최대 5줄.
  - `parse_ips(text: str) -> dict` — `{"pid", "time", "udid", "exception", "message", "frames": [Frame]}`(크래시 스레드). 주소 = 이미지 `base` + `imageOffset`. `sourceFile`/`sourceLine`이 있으면 담는다.
  - `parse_slow_functions(build_log: str) -> List[dict]` — `<path>:<line>:<col>: warning: <name> took <ms>ms to type-check (limit: <n>ms)` → `{"file", "line", "name", "ms"}`, (file, line, name) 중복 제거.
  - `parse_timing_summary(build_log: str) -> Dict[str, float]` — `<범주> (<n> tasks) | <초> seconds` 줄.
  - `symbolize(frames, products_dir, repo_root, run=subprocess.run) -> List[Frame]` — `products_dir` 아래에서 이미지 파일 이름으로 바이너리를 찾고, `xcrun dsymutil <바이너리> -o <임시 dSYM>` → `xcrun atos -fullPath -o <dSYM DWARF> -l <base> <주소…>`. 저장소 안 경로면 `file`을 저장소 기준 상대 경로로, 아니면 `None`.
  - `is_our_frame(frame) -> bool` — `file`이 있고, 함수가 진입점(`main`, `$main`, `static PayLabApp.$main()`)이 아님.
  - `collect(since, device, products_dir, build_logs, repo_root, run=subprocess.run) -> dict` — 보고서:
    ```json
    {"version": 1, "commit": "<sha>", "branch": "<이름>",
     "problems": [
       {"kind": "hang", "duration_ms": 412, "time": "...", "frames": [Frame], "files": ["Modules/..."], "context": ["..."]},
       {"kind": "crash", "exception": "...", "message": "...", "time": "...", "frames": [Frame], "files": [...], "context": [...]},
       {"kind": "slow-function", "name": "instance method 'x()'", "file": "Modules/...", "line": 12, "ms": 150, "files": ["Modules/..."]}],
     "timing": {"SwiftCompile": 23.0}}
    ```
    `Frame = {"image", "address", "base", "symbol", "function", "file", "line"}`. 우리 코드 프레임이 없는 hang은 `problems`에서 빼고 `"ignored_hangs"` 개수만 남긴다. 크래시는 `~/Library/Logs/DiagnosticReports/PayLab-*.ips` 중 `udid == device`이고 시각 ≥ `since`인 것만. 로그는 `xcrun simctl spawn <device> log show --start <since> --style ndjson --info --debug --predicate 'subsystem == "com.example.paylab"'`.
  - CLI: `python3 -I scripts/perf-report.py collect --since "<YYYY-MM-DD HH:MM:SS>" --device <UDID> --products <dir> [--build-log <path>]... --out <path>`
- 테스트 파일은 `importlib.util.spec_from_file_location`으로 `perf-report.py`를 읽는다. 외부 명령은 가짜 `run`으로 바꾼다. fixture에는 실제 개인 경로 대신 `/Users/tester/...`를 쓴다.

- [ ] **Step 1: 실패 테스트** (`unittest`)
  - `test_parse_hang_log_groups_frames_and_context`: fixture → hang 1건, `duration_ms == 412`, 프레임 3개(순서 유지), `context`가 직전 `history` 줄들.
  - `test_parse_hang_log_without_frames`: 요약 줄만 → 프레임 0개.
  - `test_parse_ips_faulting_thread`: 예외 종류, 프레임 주소 = base + offset, `udid`.
  - `test_parse_slow_functions_dedupes`: 같은 경고 2번 → 1건, `ms == 150`.
  - `test_parse_timing_summary`: `SwiftCompile (31 tasks) | 23.010 seconds` → `23.01`.
  - `test_symbolize_maps_repo_paths`: 가짜 `run`이 atos 출력 `HistoryModel.load() (in PayLab.debug.dylib) (<repo>/Modules/HomeFeature/Sources/HistoryModel.swift:42)` → `file == "Modules/HomeFeature/Sources/HistoryModel.swift"`, `line == 42`, `function == "HistoryModel.load()"`.
  - `test_entrypoint_is_not_our_frame`: `static PayLabApp.$main()`(파일 있음) → `False`.
  - `test_hang_without_our_frames_is_ignored`: 프레임이 모두 시스템 → `problems` 0건, `ignored_hangs == 1`.
  - `test_collect_ignores_other_device_crash` (Review Focus 1), `test_collect_ignores_crash_before_since` (Review Focus 5).
- [ ] **Step 2:** 스크립트 테스트. Expected: 실패(파일·함수 없음).
- [ ] **Step 3: 구현** — 위 Interfaces대로.
- [ ] **Step 4:** 스크립트 테스트. Expected: `OK`.
- [ ] **Step 5: 실제 확인** — 시뮬레이터에서 앱 실행 뒤 `collect --since <5분 전> --device "$UDID" --products .build/DerivedData/Build/Products/Debug-iphonesimulator --out .build/perf/report.json` → 오류 없이 `problems: []`.
- [ ] **Step 6: Commit**

```bash
git add scripts/perf-report.py scripts/test_perf_report.py scripts/fixtures
git commit -m "feat: perf-report collect — hang 로그·크래시 리포트·빌드 경고 수집과 기호화"
```

---

### Task 4: `perf-report.py report` — 판정·이슈·PR 코멘트

**Files:**
- Modify: `scripts/perf-report.py`, `scripts/test_perf_report.py`

**Interfaces:**
- Consumes: Task 3 보고서 JSON.
- Produces:
  - `changed_files(repo_root, mode, ref=None, run=subprocess.run) -> Set[str]` — `mode`: `"merge-base"`(origin/main merge-base 이후 + 스테이징 + 미스테이징 + 추적 안 하는 새 파일), `"ref"`(`git diff --name-only <ref> HEAD`), `"none"`(빈 집합).
  - `classify(problem, changed) -> str` — `problem["files"]`와 `changed`가 겹치면 `"change"`, 아니면 `"existing"`. `build-time`은 호출 쪽에서 정한다(PR = change, main = existing).
  - `signature(problem) -> str` — `hang|<가장 안쪽 우리 함수>`, `crash|<예외 종류>|<가장 안쪽 우리 함수 또는 ->`, `slow-function|<file>|<name>`(줄 번호 없음), `build-time`.
  - `sanitize(text, repo_root) -> str` — 홈 경로 → `~`, `/Users/<아무개>/` → `~/`, `/Users/runner/work/PayLab/PayLab/`·`repo_root/` → 빈 문자열, UDID → `<UDID>`, 메일 → `<email>`, `gh[pousr]_…`·`sk-…` → `<token>`, `socket.gethostname()` → `<host>`.
  - `issue_title(problem) -> str` — `[hang] HistoryModel.load() 412ms`, `[crash] EXC_BREAKPOINT HistoryModel.load()`, `[slow-build] HistoryModel.swift instance method 'x()' 150ms`, `[slow-build] 우리 코드 컴파일 시간 +35% (+14초)`.
  - `issue_body(problem, found) -> str` — 설계 §6.6 본문 + `<!-- perf-signature: <signature> -->` + 발생 기록 블록 `<!-- perf-occurrences:start -->`…`<!-- perf-occurrences:end -->`(횟수, 마지막 발견, 최근 5곳). `found = {"where": "로컬"|"CI", "branch", "commit", "run_url", "time"}`. 전체를 `sanitize`.
  - `record_occurrence(body, found) -> str` — 블록의 횟수 +1, 마지막 발견 교체, 최근 5곳 유지. 블록이 없으면 새 블록을 끝에 붙인다.
  - `build_regression(current, baseline, ratio=0.30, min_seconds=10.0) -> Optional[dict]` — `current`/`baseline[i]` = `{"swift_compile_s", "system_modules_s", "ratio"}`(Task 7 `build-metrics.json`). 기준 5개 미만이면 `None`. 비정상이면 문제 하나를 돌려준다: `{"kind": "build-time", "files": [], "increase_pct", "increase_s", "current", "median"}`.
  - `class GitHub(run=subprocess.run)`: `ensure_labels()`, `issues() -> List[dict]`(`perf-auto` 라벨, 열림·닫힘 모두, number/state/title/body), `create_issue(title, body, labels)`, `edit_issue_body(number, body)`, `upsert_pr_comment(pr, body)`(본문 표식 `<!-- paylab-perf-report -->`로 찾아 고치거나 새로 씀). 모두 `gh` 호출.
  - `report(data, where, changed, github, pr=None, baseline=None, metrics=None, dry_run=False, out_dir=".build/perf") -> int`

    | where | 이번 변경 | 기존 |
    |---|---|---|
    | `local` | 출력 + 종료 코드 1 | 열린 이슈 있으면 발생 기록 갱신, 없으면 새 이슈. 닫힌 이슈만 있으면 출력만. **느린 함수는 무시** |
    | `pr` | PR 코멘트(변경 문제 목록·수치. 문제 없고 기존 코멘트 있으면 "문제 없음"으로 고침) | 열린 이슈 갱신 / 없으면 새 이슈 / 닫힌 것만 있으면 새 이슈 + 이전 이슈 링크 |
    | `main` | 없음 | `pr`의 기존 규칙과 같음 |

    `gh` 실패 시: 경고 출력, 만들려던 이슈를 `out_dir/pending-issues.json`에 쓰고 계속(종료 코드에 영향 없음). 출력 줄: `[이번 변경] <제목> <파일:줄>` / `[기존 → 이슈 #<n>] <제목>` / `성능 문제 없음`.
  - CLI: `report --input <json> --where local|pr|main [--changed-from <ref> | --no-changes] [--pr <n>] [--baseline-dir <dir>] [--metrics <json>] [--dry-run]`. `--where local` 기본은 merge-base. 입력 파일이 없으면 `보고서 없음` 출력 후 0.
  - CLI: `changed-swift` — merge-base 기준 변경 파일 중 존재하는 `.swift`를 줄마다 출력.

- [ ] **Step 1: 실패 테스트** (가짜 `GitHub`는 호출을 기록하는 클래스)
  - `test_classify_change_when_any_frame_file_changed` / `test_classify_existing_when_no_overlap`.
  - `test_signature_ignores_line_number`: 같은 함수, 줄 12 vs 30 → 같은 서명.
  - `test_sanitize_removes_machine_info`: 홈 경로·러너 경로·UDID·메일·토큰·호스트 이름이 모두 바뀐다.
  - `test_local_change_blocks_without_issue`: 종료 코드 1, 이슈 생성 0.
  - `test_local_existing_creates_issue_with_labels`: 라벨 `["perf-auto", "hang"]`, 본문에 서명 표식, 개인 경로 없음.
  - `test_existing_open_issue_records_occurrence`: 같은 서명 열린 이슈 → 생성 0, `edit_issue_body` 1번, 본문 횟수 2.
  - `test_record_occurrence_without_markers_appends_block` (Review Focus 3).
  - `test_local_closed_only_does_not_create` / `test_ci_closed_only_creates_with_link`(본문에 `#<이전 번호>`).
  - `test_local_ignores_existing_slow_function`.
  - `test_pr_change_upserts_comment` / `test_pr_existing_creates_issue` / `test_main_treats_all_as_existing`.
  - `test_build_regression_thresholds`: 기준 4개 → `None`, +29% → `None`, +31%·+5초 → `None`, +31%·+12초 → dict.
  - `test_local_gh_failure_does_not_block` (Review Focus 2): 가짜 `run`이 예외 → 종료 코드 0, `pending-issues.json` 생김.
  - `test_report_missing_input_exits_zero` (Review Focus 4).
- [ ] **Step 2:** 스크립트 테스트. Expected: 새 테스트 실패.
- [ ] **Step 3: 구현** — 위 Interfaces대로.
- [ ] **Step 4:** 스크립트 테스트. Expected: `OK`.
- [ ] **Step 5: Commit**

```bash
git add scripts/perf-report.py scripts/test_perf_report.py
git commit -m "feat: perf-report report — 이번 변경/기존 판정, 이슈·발생 기록·PR 코멘트"
```

---

### Task 5: `test-all.sh` 연결 + 느린 함수 경고

**Files:**
- Modify: `scripts/test-all.sh`, `Project.swift`

**Interfaces:**
- Consumes: Task 3 `collect`, Task 4 `report`·`changed-swift`.
- Produces: `.build/perf/report.json`(로컬 보고서), `test-all.sh`의 스크립트 테스트 줄 `perf-report 테스트: OK`.

- [ ] **Step 1: `Project.swift`** — `settings`에 Debug 전용 `OTHER_SWIFT_FLAGS = "$(inherited) -Xfrontend -warn-long-function-bodies=100 -Xfrontend -warn-long-expression-type-checking=100"`. `tuist generate --no-open` 후 빌드 → 경고 0개(로컬 최대 66ms).
- [ ] **Step 2: `test-all.sh`**
  - 시뮬레이터 부팅 뒤 `since=$(date '+%Y-%m-%d %H:%M:%S')`, UDID를 구한다(`CLAUDE.md` "준비"의 방식).
  - 빌드 전에 `python3 -I scripts/perf-report.py changed-swift`의 파일들을 `touch`한다(설계 §6.5: 증분 빌드에서도 경고가 다시 나오게).
  - `trap … EXIT`로 마무리 함수: 테스트 단계에 들어갔으면 성공·실패와 상관없이 `collect --build-log .build/TestResults/PayLab.log --build-log .build/TestResults/PayLabUITests.log` → `report --where local`. 원래 실패면 원래 종료 코드, 원래 성공인데 `report`가 1이면 `실패: 이번 변경의 성능 문제`와 함께 1. 모두 성공일 때만 마지막 줄 `ALL TESTS PASSED`.
  - hook 테스트 다음에 `python3 -I scripts/test_perf_report.py`를 돌린다(실패 시 `fail "perf-report 테스트"`).
- [ ] **Step 3:** `scripts/test-all.sh`(깨끗한 작업 트리). Expected: `성능 문제 없음`, `ALL TESTS PASSED`. 걸린 시간을 기록한다(600초보다 충분히 작아야 함).
- [ ] **Step 4: 느린 함수 시연** — 변경 파일 하나(예: `HomeModel.swift`)에 타입 검사가 100ms를 넘는 식을 잠깐 넣는다(로컬 빌드 경고로 넘는 것을 먼저 확인). `scripts/test-all.sh 2>&1 | tee .build/perf/demo-slow-function.txt`. Expected: `[이번 변경] [slow-build] …`와 실패 종료. 이슈는 생기지 않는다. 식을 되돌린다.
- [ ] **Step 5:** `scripts/test-all.sh`. Expected: `ALL TESTS PASSED`.
- [ ] **Step 6: Commit**

```bash
git add scripts/test-all.sh Project.swift
git commit -m "feat: test-all.sh 마지막에 성능 수집·판정, Debug 느린 함수 경고 100ms"
```

---

### Task 6: 거래 내역 화면 + hang 시연

**Files:**
- Create: `Modules/HomeFeature/Sources/HistoryModel.swift`, `Modules/HomeFeature/Sources/HistoryView.swift`
- Modify: `Modules/HomeFeature/Sources/HomeModel.swift`, `HomeView.swift`, `AccountRow.swift`
- Modify: `Modules/HomeFeature/Tests/StubBankingRepository.swift` (거래 내역 결과 주입)
- Test: `Modules/HomeFeature/Tests/HistoryModelTests.swift`, `Modules/App/Tests/AppIntegrationTests.swift`, `Modules/App/UITests/HistoryUITests.swift`

**Interfaces:**
- Consumes: Task 1 `fetchTransactions(accountID:)`, `FakeServer.transactionsPerAccount`.
- Produces:
  ```swift
  @MainActor @Observable public final class HistoryModel {
      public struct Row: Identifiable, Equatable, Sendable { public let id: String; public let title: String; public let time: String; public let amount: String }
      public struct Section: Identifiable, Equatable, Sendable { public let id: String; public let rows: [Row] }  // id = 날짜 제목
      public let account: Account
      public private(set) var sections: [Section]
      public private(set) var isLoading: Bool
      public private(set) var loadFailed: Bool
      public init(account: Account, repository: any BankingRepository)
      public func load() async
  }
  // HomeModel
  public func makeHistoryModel(for account: Account) -> HistoryModel
  ```
  - 묶음: 날짜(Asia/Seoul) 내림차순, 묶음 안 시각 내림차순. 날짜 제목 `M월 d일 EEEE`(ko_KR, 예 `11월 12일 목요일`), 시각 `HH:mm`, 금액 `+12,000원` / `-3,500원`.
  - 실패: `loadFailed = true`, 기존 `sections` 유지.
  - 로그 category `history`: `load start account=<id>` (debug), `load ok account=<id> count=<n> sections=<m>` (info), `load failed account=<id>: <오류>` (error).
  - 진입: 계좌 행의 이름·번호·잔액 영역을 누르면 `HistoryView`로 이동, `송금` 버튼은 그대로. 내비게이션 제목 `거래 내역`.

- [ ] **Step 1: 실패 테스트 — `HistoryModelTests`** (가짜 저장소에 고정 시각 거래 4건, 두 날짜에 걸침, 섞인 순서)
  - `loadGroupsByDayNewestFirst`: 섹션 2개, 제목·순서, 각 섹션 행 시각 내림차순.
  - `rowFormats`: 입금 12,000 → `+12,000원`, 출금 3,500 → `-3,500원`, 시각 `HH:mm`.
  - `loadFailureKeepsSections`: 성공 뒤 실패 → `sections` 그대로, `loadFailed == true`, `isLoading == false`.
- [ ] **Step 2: 실패 테스트 — 통합·UI**
  - `AppIntegrationTests.historyLoadsAllTransactions`: `HistoryModel(account: <acc-main>, repository: AppEnvironment.makeRepository(arguments: []))` → `load()` → 행 합계 `FakeServer.transactionsPerAccount`.
  - `HistoryUITests.testHistoryOpensAndScrolls`: 홈 `1,250,000원` 대기 → `PayLab 통장` 탭 → 내비게이션 바 `거래 내역` 대기 → 첫 행 문구 대기 → `swipeUp()` 3번 → 앱이 살아 있음.
- [ ] **Step 3: 흔한 실수 버전 구현** — `load()` 안 메인에서 정렬·묶음, 거래마다 `DateFormatter`를 새로 만든다. 뷰·내비게이션까지 완성. 모듈 테스트 `HomeFeatureTests` → SUCCEEDED.
- [ ] **Step 4: hang 시연** — `scripts/test-all.sh 2>&1 | tee .build/perf/demo-hang-blocked.txt`. Expected: `[이번 변경] [hang] HistoryModel…`과 실패 종료, 이슈 0건. hang이 안 나면(`log show`에 `hang` 줄 없음) `transactionsPerAccount`를 늘려 다시 한다.
- [ ] **Step 5: 고치기** — 정렬·묶음·포맷을 메인 밖(`nonisolated`/`@concurrent` 정적 함수)으로 옮기고, 포맷터는 한 번만 만든다. 모듈 테스트 `HomeFeatureTests`, `PayLabTests`, UI 테스트 → SUCCEEDED.
- [ ] **Step 6:** `scripts/test-all.sh`. Expected: `성능 문제 없음`, `ALL TESTS PASSED`.
- [ ] **Step 7: Claude 확인** — 앱 설치·실행, 계좌 행 탭, 스크롤. 스크린샷 `.build/screens/history.png`, `.build/screens/history-scrolled.png`. 같은 시간대 `log show`에 `hang` 줄 없음.
- [ ] **Step 8: Commit** (고친 버전만)

```bash
git add Modules
git commit -m "feat: 거래 내역 화면 — 무거운 정렬·포맷은 메인 밖에서"
```

---

### Task 7: CI 측정·보고

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `scripts/perf-report.py`, `scripts/test_perf_report.py` (`ci-metrics`)

**Interfaces:**
- Consumes: Task 3 `collect`, Task 4 `report`.
- Produces:
  - artifact `perf-report` (`.build/perf/report.json`), artifact `build-metrics` (`build-metrics.json`).
  - `build-metrics.json` = `{"commit", "swift_compile_s", "system_modules_s", "ratio", "xcodebuild_start_s", "build_step_s"}`. `system_modules_s` = `SwiftExplicitDependency`로 시작하는 범주 합. `ratio` = `swift_compile_s / system_modules_s`(0이면 `null`, 판정은 `swift_compile_s`로).
  - CLI `ci-metrics --report <json> --run-id <id> --out <json>`: 타이밍은 보고서에서, `build_step_s`는 jobs API의 `build-and-test` 잡 `빌드` 단계 시작·끝, `xcodebuild_start_s`는 잡 로그에서 그 단계 시작 → 첫 `Command line invocation` 줄 시각.

- [ ] **Step 1: 실패 테스트** — `test_ci_metrics_from_jobs_and_log`: 가짜 jobs JSON·로그 → `build_step_s == 376`, `xcodebuild_start_s == 263`(설계 §1 실측값으로 fixture 작성), `ratio` 계산.
- [ ] **Step 2: 구현** `ci-metrics`. 스크립트 테스트 → `OK`.
- [ ] **Step 3: `build-and-test` 잡** (권한 그대로 읽기만)
  - 빌드 전: `.build` 만들기, `PERF_SINCE`(`date '+%Y-%m-%d %H:%M:%S'`)와 `UDID`를 `$GITHUB_ENV`에.
  - 빌드: `set -o pipefail` + `-showBuildTimingSummary` + `| tee .build/build.log`.
  - `if: always()` 수집: `python3 -I scripts/perf-report.py collect --since "$PERF_SINCE" --device "$UDID" --products .build/DerivedData/Build/Products/Debug-iphonesimulator --build-log .build/build.log --out .build/perf/report.json`.
  - `if: always()` 업로드 `perf-report`(`if-no-files-found: ignore`).
- [ ] **Step 4: 새 잡 `perf-report`** (ubuntu-latest)
  - `needs: build-and-test`, `if: ${{ !cancelled() && (github.event_name == 'push' || github.event.pull_request.author_association == 'OWNER') }}`, `timeout-minutes: 10`.
  - `permissions: contents: read, issues: write, pull-requests: write, actions: read`. `env: GH_TOKEN: ${{ github.token }}`.
  - checkout `fetch-depth: 2` → `perf-report` 다운로드(실패해도 계속) → `ci-metrics --run-id ${{ github.run_id }}`.
  - PR: 최근 main 성공 push 실행 5개의 `build-metrics`를 `baseline/<id>/`로 받고(없으면 넘어감) `report --where pr --pr <번호> --changed-from HEAD^1 --baseline-dir baseline --metrics …`.
  - main push: `report --where main --metrics …` → `build-metrics` 업로드.
  - 측정값 표를 `$GITHUB_STEP_SUMMARY`에 쓴다.
  - 처음 PR에서는 `report`에 `--dry-run`을 붙인다(Task 9에서 기준을 확인한 뒤 뗀다).
- [ ] **Step 5: 로컬 확인** — fixture 보고서로 `report --where pr --pr 0 --no-changes --dry-run`이 오류 없이 끝난다. YAML은 Task 9의 CI 실행으로 확인한다.
- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci.yml scripts/perf-report.py scripts/test_perf_report.py scripts/fixtures
git commit -m "ci: 빌드 타이밍·hang·크래시 수집, 보고 잡(이슈·PR 코멘트)"
```

---

### Task 8: 문서, 기존 문제 시연, 첫 이슈

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: `CLAUDE.md` `## 성능`** (설계 §6.11)
  - 문제 종류·기준 표, 판정 규칙(변경 파일 ∩ 스택 파일), 이슈 라벨·서명·발생 기록, 닫힌 이슈 규칙(로컬은 출력만).
  - 로컬: `test-all.sh`가 막았을 때 읽는 곳(`.build/perf/report.json`, 출력의 `[이번 변경]` 줄), 시뮬레이터 확인 뒤 명령 `collect --since <확인 시작> …` → `report --where local`.
  - CI: `perf-report` 잡, artifact, 잡 요약, PR 코멘트·이슈 조건.
  - 이슈의 스택 → `## 디버깅` "멈춤"·"크래시" 절차로 원인 조사.
  - 로그 표에 `hang`, `history` 행. 테스트 개수 갱신. `test-all.sh` 설명에 성능 단계 추가.
- [ ] **Step 2: 기존 문제 → 이슈 시연** (설계 §6.10, 공개 이슈가 남는다 — 설계 승인 범위)
  - Task 6 Step 3의 흔한 실수 버전을 작업 트리에 잠깐 되살리고 `scripts/test-all.sh` (차단 확인).
  - `python3 -I scripts/perf-report.py report --input .build/perf/report.json --where local --no-changes` → 새 이슈 `[hang] HistoryModel…`. 한 번 더 → 같은 이슈 발생 기록 횟수 2, 새 이슈 없음.
  - 이슈 본문에 개인 경로·UDID·컴퓨터 이름이 없는지 읽는다.
  - `gh issue close <번호> --comment "시연용 이슈 (설계 §6.10). 실제 문제 아님."`. 작업 트리를 되돌린다(`git diff`가 비어야 함).
- [ ] **Step 3: 첫 `slow-build` 이슈** (설계 §6.13): 라벨 `slow-build`(자동 생성이 아니라 `perf-auto` 없음), 제목 `[slow-build] CI 첫 xcodebuild가 출력까지 263초`, 본문 = 단계별 시간 표, 근거 실행 https://github.com/BEYun/PayLab/actions/runs/42971182297, 두 번째 `xcodebuild`는 8초, 원인 추측은 추측이라고 표시.
- [ ] **Step 4:** `scripts/test-all.sh`. Expected: `ALL TESTS PASSED`.
- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md 성능 섹션 — 문제 종류·판정·이슈·CI 측정"
```

---

### Task 9: PR, CI 기준 확인

- [ ] **Step 1: 공개 전 검사** — `git log -p origin/main..HEAD | grep -nE "/Users/|gh[pousr]_|sk-|@gmail|[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"`. Expected: fixture·테스트의 가짜 값(`/Users/tester`, `/Users/runner`, 가짜 UDID)만 나온다.
- [ ] **Step 2:** `git fetch origin && git merge-tree --write-tree origin/main HEAD`로 충돌 확인. push, PR 생성. PR 설명: 요약, 시연 출력(`.build/perf/demo-*.txt` 핵심 줄), 시연 이슈·첫 이슈 링크, 스크린샷 설명, `--dry-run` 상태.
- [ ] **Step 3: 첫 CI 확인** — `build-and-test` 통과, `perf-report` 잡 로그에서 dry-run 결과를 읽는다.
  - 느린 함수: PR과 무관한 기존 함수가 100ms를 넘으면 그 최대값보다 여유 있게 기준을 올린다(`Project.swift` 플래그 두 개). 설계 §6.1 해당 줄에 실측값과 새 기준을 적는다.
  - `ignored_hangs`, 크래시 0건 확인. 측정값 표(잡 요약) 확인.
  - 늘어난 CI 시간: 수집 단계 + `perf-report` 잡이 합쳐 1분 안쪽인지 본다(설계 §6.8). 넘으면 원인(기호화, 다운로드)을 PR 설명에 적는다.
- [ ] **Step 4:** `--dry-run`을 떼고 커밋·push. 두 번째 CI: 통과, PR 코멘트 없음(이번 변경의 문제 없음), 새 이슈 없음.
- [ ] **Step 5:** 병합은 사용자 확인 뒤 squash. 병합 후 main push CI에서 `build-metrics` artifact가 올라가는지 확인한다.
