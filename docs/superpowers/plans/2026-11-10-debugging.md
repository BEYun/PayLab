# 디버깅 용이성 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 화면 밖 사건을 `os.Logger`로 남기고, Claude용 조사 절차를 `CLAUDE.md`에 적고, 블라인드 연습 5회로 둘 다 쓸모 있는지 검증한다.

**Architecture:** 모듈마다 파일 안에 `Logger` 상수 한 줄을 둔다(공통 모듈 없음). 네트워크 로그는 앱 쪽 `RemoteBankingRepository.send`, 화면 로그는 `HomeModel`·`TransferModel`에 붙인다. 화면 동작은 바꾸지 않는다. 연습은 메인 세션이 출제·해결 서브에이전트를 차례로 띄워 진행한다.

**Tech Stack:** Swift 6, SwiftUI, `os.Logger`, `xcrun simctl`, `log`, `sample`, `leaks`, `heap`, iOS 시뮬레이터 도구(`mcp__Claude_Code_iOS_Simulator__control`).

**Spec:** `docs/superpowers/specs/2026-11-10-debugging-design.md`

## Global Constraints

- subsystem: `com.example.paylab`. 카테고리: `app`, `network`, `home`, `transfer`.
- 모든 문자열 보간에 `privacy: .public`. 정수·불리언도 명시해 일관되게 쓴다.
- 응답 본문 원문은 `#if DEBUG` 안에서만 로그에 남긴다 (Debug 구성에 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` 확인함).
- 레벨: 정상 흐름 `debug`/`info`, 실패 `error`.
- 기존 화면 동작 불변: `HomeModel.load` 실패 시 기존 목록 유지, `loadRecipients` 실패 시 빈 목록, `submit` 실패 시 `.failure` 후 `.result`로 이동.
- 외부 라이브러리 금지. 테스트 코드 추가 금지 (테스트 세션 몫). 검증은 빌드·기존 테스트 6개·시뮬레이터 로그로 한다.
- `CLAUDE.md`는 기존 줄을 건드리지 않고 `## 디버깅` 섹션만 추가한다.
- 시뮬레이터: `PayLab-$(git branch --show-current)` (이 브랜치는 `PayLab-claude/debugging-a7a6f0`, 이미 생성됨). 부팅 직후에는 `xcrun simctl bootstatus "<시뮬레이터>" -b`로 기다린 뒤 실행한다.
- 로그를 읽을 때: `log stream`을 백그라운드로 띄워 scratchpad 파일에 저장 → 앱 실행·조작 → 파일을 읽는다.

## Review Focus

1. **로그가 `<private>`로 가려짐** → 시뮬레이터 `log stream` 출력에 `<private>`가 0개여야 한다. Task 1·2 검증 단계에서 grep으로 확인.
2. **응답 원문이 Release 로그에 남음** → 본문 로그 줄이 `#if DEBUG` 안에 있어야 한다. Task 1 검증 단계에서 소스 grep으로 확인.
3. **로그 추가가 화면 동작을 바꿈** → `--fail-transfer` 실행에서 결과 화면에 "실패", 일반 실행에서 송금 후 홈 잔액 반영. Task 2 검증 단계.
4. **다른 세션 시뮬레이터의 PayLab 프로세스를 잡음** (테스트·CI 세션도 PayLab을 띄운다) → `CLAUDE.md`의 PID 조회 명령은 이 브랜치 시뮬레이터의 PID 하나만 내야 한다. Task 3 검증 단계.
5. **긴 응답 본문이 로그에서 잘림** → 응답 줄에 본문 바이트 수를 남겨, 원문 줄이 짧으면 잘린 것을 알 수 있게 한다. `CLAUDE.md`에 한 줄로 적는다. Task 1·3.

---

### Task 1: 네트워크·앱 로그

**Files:**
- Modify: `Modules/DataKit/Sources/RemoteBankingRepository.swift` (`send`, 디코딩 오류 설명 함수 추가)
- Modify: `Modules/App/Sources/AppEnvironment.swift` (`makeRepository`)

**Interfaces:**
- Produces (Task 3 `CLAUDE.md`가 이 문구로 grep한다):
  - `network` 카테고리
    - `debug`: `request <METHOD> /<path>`
    - `info`: `response <status> <METHOD> /<path> <ms>ms <bytes>B` (2xx일 때)
    - `error`: `response <status> <METHOD> /<path> <ms>ms <bytes>B` (2xx가 아닐 때, 같은 문구)
    - `debug` (DEBUG만): `body <METHOD> /<path> <원문>`
    - `error`: `decode failed <타입> <METHOD> /<path>: <설명>`. 설명 형식은 `typeMismatch(Int) at [0].balance: <debugDescription>` / `keyNotFound(balance) at [0]: …` / `valueNotFound(Int) at [0].balance: …` / `dataCorrupted at <경로>: …`. 경로는 정수 키는 `[n]`, 문자열 키는 `.key`로 잇는다(맨 앞 `.`은 뗀다). 경로가 비면 `<root>`.
    - `error`: `transport failed <METHOD> /<path>: <error>`
    - 디코딩 실패 때는 DEBUG 빌드라도 `body` 줄을 한 번 더 `error` 레벨로 남긴다(원문과 오류를 바로 대조하도록).
  - `app` 카테고리 `info`: `launch failTransfers=<true|false>`
- 기존 동작 유지: 비 2xx면 `BankingError.server(statusCode:)`를 던지고, 디코딩·전송 오류는 원래 오류를 그대로 다시 던진다.

- [ ] **Step 1: `RemoteBankingRepository.swift`에 로그 추가**

  파일 위에 `import os`와 `private let log = Logger(subsystem: "com.example.paylab", category: "network")`. 걸린 시간은 `ContinuousClock`으로 잰다. 디코딩 오류 설명은 `private func describe(_ error: DecodingError) -> String`로 둔다.

- [ ] **Step 2: `AppEnvironment.makeRepository`에 `launch` 로그 추가**

  `private let log = Logger(subsystem: "com.example.paylab", category: "app")`.

- [ ] **Step 3: 빌드·기존 테스트**

  Run: `CLAUDE.md`의 build, test 명령.
  Expected: `** BUILD SUCCEEDED **`, Swift Testing 줄에 6 tests passed.

- [ ] **Step 4: 정상 실행 로그 확인**

  `xcrun simctl spawn "PayLab-$(git branch --show-current)" log stream --level debug --style compact --predicate 'subsystem == "com.example.paylab"'`를 백그라운드로 띄워 scratchpad 파일로 저장 → install → launch → 3초 뒤 파일 확인.
  Expected: `launch failTransfers=false`, `request GET /accounts`, `response 200 GET /accounts …ms …B`, `body GET /accounts [{"id":"acc-main"…`. `grep -c '<private>'` = 0.

- [ ] **Step 5: 디코딩 실패 로그 확인 (임시 변경 후 되돌림)**

  `FakeServer.handle`의 `GET /accounts`가 잔액을 문자열로 보내도록 임시로 바꾼다. 빌드·실행 후 로그를 확인하고 `git checkout -- Modules/DataKit/Sources/FakeServer.swift`로 되돌린다.
  Expected: `decode failed Array<Account> GET /accounts: typeMismatch(Int) at [0].balance: …`와 그 원문 `body` 줄이 `error` 레벨로 나온다. 되돌린 뒤 `git status --short`에 `FakeServer.swift`가 없다.

- [ ] **Step 6: Review Focus 2 확인**

  Run: `grep -n -B3 '"body ' Modules/DataKit/Sources/RemoteBankingRepository.swift`
  Expected: 정상 응답의 `body` 줄이 `#if DEBUG` 블록 안에 있다. 디코딩 실패 쪽 `body` 줄도 `#if DEBUG` 안에 있다.

- [ ] **Step 7: Commit**

  ```bash
  git add Modules/DataKit/Sources/RemoteBankingRepository.swift Modules/App/Sources/AppEnvironment.swift
  git commit -m "feat: 네트워크·앱 시작 로그 (os.Logger)"
  ```

### Task 2: 화면 모델 로그

**Files:**
- Modify: `Modules/HomeFeature/Sources/HomeModel.swift` (`load`)
- Modify: `Modules/TransferFeature/Sources/TransferModel.swift` (`loadRecipients`, `select`, `proceedToConfirm`, `submit`)

**Interfaces:**
- Produces (Task 3 `CLAUDE.md`가 이 문구로 grep한다):
  - `home`: `debug` `load start` / `info` `load ok accounts=<n>` / `error` `load failed keep=<기존 개수>: <error>`
  - `transfer`:
    - `debug` `recipients start` / `info` `recipients ok count=<n>` / `error` `recipients failed: <error>`
    - `info` `select recipient=<id>`
    - `info` `confirm amount=<n>` / `error` `confirm blocked amountText="<text>" amount=<n|nil> balance=<n>`
    - `info` `submit start from=<계좌 id> to=<받는 사람 id> amount=<n>` / `info` `submit ok transferID=<id> balanceAfter=<n>` / `error` `submit failed: <error>` / `error` `submit ignored recipient=<id|nil> amount=<n|nil>`
- 동작 불변: `try?`를 `do/catch`로 바꾸는 것만 허용. 성공·실패 때 상태 변화는 지금과 같다.

- [ ] **Step 1: `HomeModel.load`에 로그 추가**

  `import os`, `private let log = Logger(subsystem: "com.example.paylab", category: "home")`.

- [ ] **Step 2: `TransferModel` 네 메서드에 로그 추가**

  `import os`, `private let log = Logger(subsystem: "com.example.paylab", category: "transfer")`. `proceedToConfirm`·`submit`의 `guard … else { return }`에서 `return` 전에 `error` 로그를 남긴다.

- [ ] **Step 3: 빌드·기존 테스트**

  Expected: `** BUILD SUCCEEDED **`, 6 tests passed.

- [ ] **Step 4: 정상 송금 경로 로그 + 동작 확인 (Review Focus 1·3)**

  `log stream`을 백그라운드로 띄우고, 시뮬레이터 도구로 송금 한 번을 완주한다(PayLab 통장 → 김하늘 → 10000 → 확인 → 결과 → 홈).
  Expected: 로그에 `load ok accounts=3`, `recipients ok count=3`, `select recipient=rcp-1`, `confirm amount=10000`, `submit start from=acc-main to=rcp-1 amount=10000`, `submit ok …`, 이어서 두 번째 `load ok accounts=3`. 홈 스크린샷에서 PayLab 통장 잔액이 1,240,000원. `grep -c '<private>'` = 0.

- [ ] **Step 5: 실패 주입 로그 + 동작 확인 (Review Focus 3)**

  `--fail-transfer`로 실행해 송금을 끝까지 진행한다.
  Expected: 결과 화면에 "실패". 로그에 `launch failTransfers=true`, `response 500 POST /transfers`(error), `submit failed: server(statusCode: 500)`.

- [ ] **Step 6: Commit**

  ```bash
  git add Modules/HomeFeature/Sources/HomeModel.swift Modules/TransferFeature/Sources/TransferModel.swift
  git commit -m "feat: 홈·송금 모델 상태 로그"
  ```

### Task 3: `CLAUDE.md` 디버깅 섹션

**Files:**
- Modify: `CLAUDE.md` (맨 끝 `## 금지` 섹션 앞에 `## 디버깅` 추가. 기존 줄은 한 글자도 바꾸지 않는다)

**Interfaces:**
- Consumes: Task 1·2의 로그 문구.
- Produces (Task 4 해결 에이전트는 이 섹션만 보고 일한다):
  1. 로그 체계: subsystem, 카테고리 4개와 각 카테고리가 남기는 사건 한 줄씩. 레벨 의미. 응답 줄의 바이트 수로 원문 잘림을 알아챈다는 한 줄.
  2. 공통 명령: 부팅 대기(`bootstatus -b`), `log stream` 백그라운드 저장, 사후 조회 `log show --last 5m --info --debug --style compact --predicate …`, 이 브랜치 시뮬레이터의 PayLab PID 조회, 스크린샷(`xcrun simctl io <시뮬레이터> screenshot <경로>` 또는 시뮬레이터 도구).
  3. 유형별 절차 5개(디코딩 / 무반응·렌더링 / 멈춤 / 메모리 누수 / 메인 스레드 위반): 각각 무엇을 실행하고, 출력에서 무엇을 찾고, 그다음 무엇으로 좁히는지.
     - 무반응·렌더링: "모델 로그에는 데이터가 왔는데 스크린샷에 없다 → 뷰 쪽", "요청 로그가 없다 → 호출 안 됨", "`blocked`/`ignored` 줄 → guard" 같은 구분표.
     - 누수: `leaks <pid>`, 할당 위치가 필요하면 `SIMCTL_CHILD_MallocStackLogging=1`로 실행, `heap <pid>`로 PayLab 타입 인스턴스 수를 동작 반복 전후로 비교. 앱 시작 직후 타입 없는 `ROOT LEAK` 1개(32바이트)는 잡음.
     - 메인 스레드 위반: 크래시 리포트 `~/Library/Logs/DiagnosticReports/PayLab-*.ips`에서 볼 필드. Main Thread Checker를 켜고 실행하는 명령. Thread Sanitizer 빌드 명령(`-enableThreadSanitizer YES`).

- [ ] **Step 1: 명령 검증 (건강한 앱 대상)**

  섹션에 넣을 명령을 하나씩 실제로 돌린다.
  Expected:
  - PID 조회 명령이 `simctl launch` 출력의 PID와 같은 숫자 하나만 낸다 (Review Focus 4).
  - `sample <pid> 1`은 콜 그래프를 낸다.
  - `heap <pid>` 출력에서 PayLab 모듈 타입(예: `HomeFeature.HomeModel`)을 grep할 수 있다.
  - `SIMCTL_CHILD_MallocStackLogging=1` 실행 후 `leaks <pid>`가 돈다.
  - `log show` 사후 조회가 Task 2의 로그를 낸다.
  - Main Thread Checker를 넣어 실행해도 앱이 뜬다. 안 뜨면 이 항목은 "Swift 6 런타임 격리 검사 크래시 + Thread Sanitizer"로 대체하고, 대체한 사실을 섹션에 적는다.
  - `kill -ABRT <pid>` 뒤 새 `.ips`가 생기고, 섹션의 필드 추출 명령이 예외 종류와 크래시 스레드 프레임을 낸다.

- [ ] **Step 2: 섹션 작성**

  Step 1에서 실제로 동작한 명령만 넣는다. 각 명령에는 무엇을 보려는 명령인지 오른쪽 주석으로 짧게 단다.

- [ ] **Step 3: 기존 줄 불변 확인**

  Run: `git diff CLAUDE.md | grep '^-' | grep -v '^---'`
  Expected: 출력 없음.

- [ ] **Step 4: Commit**

  ```bash
  git add CLAUDE.md
  git commit -m "docs: CLAUDE.md 디버깅 섹션 (로그·도구 조사 절차)"
  ```

### Task 4: 블라인드 연습 5회

**메인 세션이 직접 진행한다** (출제·해결 서브에이전트를 메인 세션이 띄운다). 서브에이전트가 시뮬레이터 도구를 처음 쓸 때 사용자에게 권한 요청이 뜰 수 있다.

**Files:**
- Create: `docs/debugging-drills.md`
- 보강이 필요하면: Task 1·2의 소스, `CLAUDE.md` 디버깅 섹션

**순서:** 디코딩 불일치 → 무반응·렌더링 실패 → 멈춤 → 메모리 누수 → 메인 스레드 위반.

**연습 1회 절차 (유형마다 반복):**

- [ ] **준비:** `git status --short`가 비어 있다(커밋 완료). 시뮬레이터 부팅 확인.
- [ ] **출제:** 새 서브에이전트 A에게 아래 프롬프트로 지시한다.

  ```text
  PayLab(저장소: <worktree 경로>, CLAUDE.md 참고)에 "<유형>" 버그를 하나 심어라.
  - 실제 앱에서 일어날 법한 실수로 만든다. 주석·이름·로그로 힌트를 남기지 않는다. 로그 코드는 지우거나 바꾸지 않는다.
  - FakeServer 변경은 "서버가 응답을 바꿨다"는 상황으로 허용한다.
  - 커밋하지 않는다. 빌드·설치 후 시뮬레이터 도구로 증상이 실제로 보이는지 확인한다.
  - 보고는 두 부분:
    [버그 신고] QA가 화면에서 본 것만. 재현 단계 포함. 원인·위치·유형·코드 용어 금지.
      화면 증상이 없는 유형이면 사람이 관찰할 수 있는 현상으로(예: 메모리 사용량이 계속 늚).
    [정답] 원인, 파일:줄, 바꾼 내용.
  ```

- [ ] **해결 1단계:** 새 서브에이전트 B에게 [버그 신고]만 넘긴다.

  ```text
  PayLab(저장소: <worktree 경로>)에서 아래 버그 신고의 원인을 찾아라. 지금은 1단계다.
  - 읽어도 되는 것: CLAUDE.md만. Modules/ 소스, docs/, git(log·diff·status·show 등) 금지.
  - 쓸 수 있는 것: CLAUDE.md 디버깅 섹션의 명령, 시뮬레이터 도구(탭·스크린샷), 빌드·설치·실행.
  - 보고: 용의 위치(화면 / 계층: 뷰·모델·저장소·서버 / 함수 이름까지 가능한 만큼), 근거가 된 로그 줄·도구 출력, 확신도.
  1단계 보고를 마치면 멈춰라. 2단계 지시는 따로 간다.
  [버그 신고] …
  ```

- [ ] **해결 2단계:** 같은 B에게 SendMessage로 "이제 Modules/ 소스를 읽어도 된다(git과 docs/는 계속 금지). 원인과 파일:줄을 확정해 보고하라."
- [ ] **채점:** [정답]과 대조. 기록 항목: 1단계에서 좁힌 범위(화면 / 계층 / 함수), 2단계 정답 여부, B가 쓴 도구, 막힌 지점.
  - 성공 = 1단계에서 정답 함수(또는 뷰)까지 좁힘, 또는 정답 계층까지 좁히고 2단계에서 맞힘.
  - 1단계에서 계층도 못 좁혔으면 2단계 정답 여부와 관계없이 빈틈이다.
- [ ] **되돌리기:** `git checkout -- .` 후 `git status --short`가 비어 있는지 확인하고, 새 파일이 생겼으면 `git clean -n`으로 확인 뒤 지운다. 다시 빌드·설치한다.
- [ ] **기록:** `docs/debugging-drills.md`에 회차 섹션 추가: 유형, 버그 신고, 정답, B 1단계 보고 요약, 2단계 결과, 채점, 빈틈과 보강.
- [ ] **빈틈이면 보강:** 무엇이 없어서 못 좁혔는지 정하고 로그나 `CLAUDE.md` 절차를 고친다. 빌드·테스트 후 커밋한다. 같은 유형의 다른 버그로 1회 더 연습한다(새 A, 새 B). 그래도 실패하면 기록하고 사용자에게 보고한다.
- [ ] **Commit:** `git add docs/debugging-drills.md` (+ 보강 파일) → `git commit -m "docs: 블라인드 연습 <n>회차 — <유형>"`

### Task 5: 마무리 검증

- [ ] **Step 1:** 빌드·테스트 명령. Expected: `** BUILD SUCCEEDED **`, 6 tests passed.
- [ ] **Step 2:** 일반 실행·`--fail-transfer` 실행에서 네 카테고리 로그가 모두 나온다(Task 2 Step 4·5 재확인).
- [ ] **Step 3:** `git status --short` 비어 있음. `docs/debugging-drills.md`에 5회차 이상 기록.
- [ ] **Step 4:** 전체 브랜치 리뷰 후 사용자에게 main 병합 여부를 묻는다. 직접 병합하지 않는다.
