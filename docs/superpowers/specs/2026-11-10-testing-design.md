# 테스트 정착 설계 — PayLab

- 작성일: 2026-11-10
- 상태: 승인 완료 (2026-11-10)
- 브랜치: `claude/testing-e79d30`
- 표기: **(제 판단)** = 사용자가 직접 정하지 않고 Claude가 정한 항목. 나머지는 사용자가 결정한 항목.
- 선행 문서: `docs/superpowers/specs/2026-11-06-foundation-design.md` (§9 테스트 인계 메모)

## 1. 의도와 이유

- 사용자가 정의한 "테스트 정착": **모든 작업이 아래 흐름을 빠짐없이 거치는 상태.**

  ```text
  기능 명세서 → 설계 → 코드 + 테스트 코드 → 단위 테스트 → 통합 테스트 → 시뮬레이터 테스트 → 커밋
  ```

- 시뮬레이터 테스트는 두 가지 모두다.
  1. UI 테스트 코드 (XCUITest)
  2. Claude가 시뮬레이터에서 앱을 직접 띄워 탭·스크린샷으로 확인
- 커밋은 **모든 테스트가 통과한 뒤에만** 한다. Claude Code hook이 이를 강제한다.
- 기반 단계가 남긴 형식적 테스트 6개(`#expect(Bool(true))`)를 실제 테스트로 바꾼다.

## 2. 목표

1. 6개 모듈(Domain, DesignSystem, DataKit, HomeFeature, TransferFeature, App) 전부에 실제 테스트. 형식적 테스트 6개 삭제.
2. UI 테스트 타깃 신설. 송금 성공 경로와 실패 주입(`--fail-transfer`) 경로.
3. Claude Code hook: `git commit` 직전 전체 테스트 실행, 실패 시 커밋 차단.
4. 코드 커버리지 측정 명령과 이 세션 종료 시점의 기준선 기록.
5. `CLAUDE.md`에 테스트 규칙 섹션 신설.

## 3. 비목표

| 하지 않는 것 | 이유 |
|---|---|
| 스냅샷 테스트, 외부 라이브러리 추가 | 사용자 결정: 도입 안 함 |
| 커버리지 기준 미달 시 커밋 차단 | 사용자 결정: 측정만 |
| 가짜 서버의 세션별 바인딩 (DataKit 코드 변경) | 사용자 결정: 통합 테스트 직렬 실행으로 해결 |
| 파일 편집 후 관련 테스트 자동 실행 hook | 요청 없음 **(제 판단)** |
| 중복 송금 방지, 재시도, 진행 중 이중 제출 방지 등 트랜잭션 로직 | 트랜잭션 세션 몫. 테스트가 부재를 드러내면 **기록만** 한다 (부록 A) |
| CI 설정 | CI 세션 몫 |
| 앱 기능·동작 변경 | 예외: UI 테스트용 접근성 식별자(`.accessibilityIdentifier`) 추가만 허용 |

## 4. 안티 목표 (돌아가도 실패로 보는 것)

- **형식 맞추기 테스트:** `#expect` 없이 호출만 하는 테스트, 구현 코드를 그대로 베낀 기대값. 커버리지 수치만 올리고 아무것도 검증하지 않는다.
- **느리거나 불안정한(flaky) 테스트:** hook이 커밋마다 전체 테스트를 돌린다. 이유 없이 실패하는 테스트가 있으면 hook을 끄거나 우회하는 습관이 생긴다. UI 테스트에 고정 `sleep` 금지, 요소 대기(`waitForExistence`)를 쓴다.
- **테스트 때문에 제품 코드 구조를 바꿈.** 위 접근성 식별자 외에는 테스트 대상 코드를 고치지 않는다.
- 다른 세션 주제(로깅, CI, 트랜잭션, 성능)를 미리 구현.

## 5. 제약

- 단위·통합 테스트: Swift Testing (`import Testing`). UI 테스트: XCTest의 `XCUIApplication`.
- **Feature 간 import 금지.** Feature 모델과 DataKit을 함께 쓰는 통합 테스트는 모든 모듈에 의존하는 App 테스트 타깃(`PayLabTests`)에만 둘 수 있다.
- **가짜 서버 등록은 프로세스 전역**(`FakeBackend.makeSession`, 마지막 호출이 이김). Swift Testing은 기본 병렬.
  - 사용자 결정: `FakeBackend.makeSession`을 (직접 또는 `AppEnvironment.makeRepository`로) 부르는 테스트는 테스트 타깃마다 `@Suite(.serialized)` 하나에 모은다. 그 밖의 테스트는 병렬 그대로.
  - 전제: 테스트 번들(타깃)은 서로 다른 프로세스에서 실행된다. 구현 첫 단계에서 확인한다. 전제가 틀리면 멈추고 사용자에게 보고한다.
- **세션별 시뮬레이터** `PayLab-<브랜치>`. 이 브랜치 이름에 `/`가 있다(`claude/testing-e79d30`). 디버깅 세션이 `/`가 든 이름으로 생성·빌드·설치·실행이 모두 동작함을 확인했다(2026-11-10). 그래도 문제가 생기면 기반 세션이 지정한 형태로만 `CLAUDE.md`를 고친다: `$(git branch --show-current)` → `$(git branch --show-current | tr / -)`, grep 패턴 끝(닫는 따옴표 앞)에 ` (` 추가.
- **CI 세션 현황** (브랜치 `claude/ci-2113c8`, 2026-11-10 확인): GitHub Actions가 공용 `PayLab` 스킴을 `build-for-testing` → `test-without-building`으로 실행한다. 이 스킴의 테스트 구성을 바꾸면 CI 실행 내용이 바뀐다.
- **`CLAUDE.md` 기존 줄 수정 금지** (세 세션 공통 규칙). 테스트 섹션만 추가한다. 예외는 위 시뮬레이터 이름 수정.
- **병렬 세션과의 충돌 최소화:**
  - 디버깅 세션이 DataKit의 `URLProtocol` 계층을 다루고, `HomeModel`·`TransferModel`에 로그 줄을 넣는다. 이 세션은 DataKit 제품 코드와 두 모델 파일을 고치지 않는다.
  - `Project.swift`는 UI 테스트 타깃 1개와 스킴 1개 추가에 필요한 줄만 고친다 (CI 세션도 고칠 수 있음).

## 6. 결정된 것

### 6.1 단계별 테스트 위치

| 흐름 단계 | 위치 | 대상 | 실행 방식 |
|---|---|---|---|
| 단위 테스트 | 각 모듈의 `Tests` | 순수 로직, `@Observable` 모델(가짜 저장소 주입), `FakeServer.handle` 직접 호출 | 병렬 |
| 통합 테스트 | `DataKitTests`의 직렬 Suite, `PayLabTests` | `RemoteBankingRepository` → `URLSession` → `FakeServerURLProtocol` → `FakeServer`, 모델까지 연결 | 직렬 |
| 시뮬레이터 테스트 ① | `PayLabUITests` (신설, 별도 스킴) | 앱을 띄워 송금 흐름을 자동으로 누름 | XCUITest |
| 시뮬레이터 테스트 ② | 코드 없음 | Claude가 앱을 설치·실행, 탭·스크린샷으로 확인 | 작업 완료 보고에 스크린샷 첨부 |

### 6.2 모듈별 최소 테스트 목록

빌더는 더 추가할 수 있다. 기대값은 아래 "현재 동작"을 고정하는 것이다. 동작이 이상해 보여도 고치지 않고 부록 A에 기록한다.

**Domain — `TransferRule.isValidAmount`**
- 0 → false, 음수 → false, 1 → true, 잔액과 같은 금액 → true, 잔액 + 1 → false

**DesignSystem — `formatWon`**
- 0 → `"0원"`, 1250000 → `"1,250,000원"`, 음수의 현재 출력

**HomeFeature — `HomeModel` (가짜 저장소)**
- `load` 성공 → `accounts` 교체
- `load` 실패 → 직전 `accounts` 유지 (먼저 성공시킨 뒤 실패시킴)
- `load` 종료 후 `isLoading == false` (성공·실패 모두)

**TransferFeature — `TransferModel` (가짜 저장소)**
- `amount` 파싱: `"1,000원"` → 1000, `""` → nil, 숫자 없음 → nil, Int 범위 초과 → nil, 전각 숫자 → nil, `"-500"` → 500 (부호가 걸러지는 현재 동작)
- `canProceed`: 금액 nil, 0, 잔액과 같음, 잔액 + 1
- `select` → `selectedRecipient` 설정, `path == [.amount]`
- `proceedToConfirm`: `canProceed`가 false면 `path` 변화 없음, true면 `.confirm` 추가
- `submit` 성공 → `.success(receipt)`, `path` 끝이 `.result`, 저장소가 받은 요청의 출금 계좌·받는 사람·금액
- `submit` 실패 → `.failure`, `path` 끝이 `.result`
- 받는 사람 미선택 상태의 `submit` → 저장소 호출 없음, 상태 변화 없음
- `loadRecipients` 성공 → 목록 설정, 실패 → 빈 목록 유지

**DataKit 단위 — `FakeServer.handle` 직접 호출 (병렬)**
- `GET /accounts` → 200, 계좌 3개. `GET /recipients` → 200, 받는 사람 3명
- 모르는 경로·메서드 → 404
- `POST /transfers` 판정 순서 (코드 순서 그대로):
  1. `failTransfers` → 500 (본문이 깨져 있어도 500)
  2. 본문 없음·디코딩 실패 → 400
  3. 모르는 출금 계좌 또는 받는 사람 → 404
  4. 금액 무효 (0, 잔액 초과) → 400
  5. 정상 → 200, `balanceAfter` = 잔액 − 금액
- 성공 시 잔액 차감 (다음 `GET /accounts`에 반영). 500·400·404면 잔액 그대로

**DataKit 통합 — `RemoteBankingRepository` + `FakeBackend.makeSession` (직렬 Suite)**
- `fetchAccounts`, `fetchRecipients` 디코딩
- `transfer` 성공 → 영수증
- 서버 500 / 404 / 400 → `BankingError.server(statusCode:)`에 같은 코드

**App 통합 — `PayLabTests` (직렬 Suite)**
- `AppEnvironment.makeRepository(arguments: [])` → 송금 성공. `["--fail-transfer"]` → `BankingError.server(statusCode: 500)`
- 실제 저장소로 연결한 `TransferModel.submit` 성공 → `HomeModel.load` 결과에 잔액 반영
- 실패 주입 시 `outcome == .failure`, `HomeModel.load` 결과 잔액 그대로

**UI — `PayLabUITests`**
- 성공: 실행 → 첫 계좌 "송금" → 받는 사람 선택 → 금액 입력 → "다음" → "보내기" → "보냈어요" 표시 → "확인" → 홈 잔액이 금액만큼 줄어듦
- 실패: `--fail-transfer`로 실행 → 같은 흐름 → "송금 실패" 표시 → "확인" → 홈 잔액 그대로
- 앱을 실행할 때마다 가짜 서버 상태는 초기화된다 (메모리 전용). 두 테스트는 서로 독립이다.

### 6.3 테스트 더블 **(제 판단)**

- `HomeFeatureTests`와 `TransferFeatureTests`가 각자 작은 가짜 저장소를 가진다. 응답과 오류를 테스트가 정하고, 받은 요청을 기록한다.
- 공유 테스트 지원 모듈은 만들지 않는다. 쓰는 곳이 두 곳뿐이라 중복을 감수한다.
- 테스트의 `FakeServer`는 `latency: .zero`. 예외: `AppEnvironment` 경유 테스트는 기본 지연(300ms)을 그대로 쓴다.

### 6.4 UI 테스트 스킴 (사용자 결정: 별도 스킴)

- 공용 `PayLab` 스킴은 지금처럼 단위·통합 테스트만 돈다. CI와 `CLAUDE.md`의 기존 테스트 명령은 바뀌지 않는다.
- `PayLabUITests` 타깃은 새 스킴(이름 `PayLabUITests`)에만 넣는다.
- CI에 UI 테스트를 넣을지는 CI 세션이 나중에 정한다.

### 6.5 커밋 hook (사용자 결정: Claude Code hook)

- 위치: 저장소의 `.claude/settings.json` (커밋한다). 이 브랜치가 main에 병합되면 모든 세션에 적용된다.
- 동작: `PreToolUse`, matcher `Bash`. 실행하려는 명령에 `git commit`이 들어 있으면 전체 테스트 스크립트를 실행한다.
  - 실패 → 종료 코드 2 + 실패 요약을 stderr로 → Claude의 커밋이 막히고 Claude가 이유를 본다.
  - 성공 → 커밋 진행.
- 전체 테스트 스크립트 **(제 판단)**: `scripts/` 아래 하나. 사람이나 Claude가 직접 실행할 때도 같은 스크립트를 쓴다.
  1. `tuist generate --no-open` (Project.swift 변경 반영)
  2. 세션 시뮬레이터 생성(없으면)·부팅 — `CLAUDE.md`와 같은 이름 규칙
  3. `PayLab` 스킴 `xcodebuild test` (단위·통합, 커버리지 켬, 결과 번들 경로 고정)
  4. `PayLabUITests` 스킴 `xcodebuild test` (UI)
- 문서만 바꾼 커밋도 전체 테스트를 돈다. 사용자 말 "모든 테스트가 완료되고 나서 커밋"을 그대로 따른 해석 **(제 판단)**.
- 스크립트의 어떤 실패든(생성·부팅·빌드·테스트) hook에서는 종료 코드 2로 바꿔 커밋을 막는다 **(제 판단)**.
- hook 제한 시간: 전체 테스트 실측 시간의 2배 이상 **(제 판단)**. hook 자체가 제한 시간을 넘기면 커밋이 막히지 않을 수 있으므로 넉넉히 잡는다.
- 사람이 터미널에서 직접 하는 커밋은 막지 않는다 (Claude Code hook의 한계, 사용자 인지).

### 6.6 커버리지 (사용자 결정: 측정만)

- 전체 테스트 스크립트가 `PayLab` 스킴(단위·통합) 실행에서 커버리지를 켠다. UI 테스트 실행 결과는 수치에 넣지 않는다. 화면을 지나가기만 해도 뷰 코드가 "실행됨"으로 잡혀 빠진 테스트가 가려지기 때문이다 **(제 판단)**.
- 모듈별 수치를 보는 명령(`xcrun xccov view --report --only-targets <결과 번들>`)을 `CLAUDE.md`에 적는다.
- 이 세션 종료 시점의 모듈별 수치를 기준선으로 `CLAUDE.md` 테스트 섹션에 기록한다. 차단은 없다.

### 6.7 `CLAUDE.md` 테스트 규칙 섹션 (신설)

- 작업 흐름 7단계와 단계별 명령
- 6.1의 테스트 위치 표
- 규칙
  - 새 코드에는 같은 작업 안에서 테스트를 함께 쓴다. 버그 수정은 재현 테스트를 먼저 쓴다.
  - `FakeBackend.makeSession`을 쓰는 테스트는 해당 타깃의 직렬 Suite에 넣는다.
  - UI 테스트에 고정 sleep 금지.
  - 시뮬레이터 확인 단계: 작업 완료 보고에 스크린샷을 첨부한다.
  - 커밋 hook이 막으면 테스트를 고친다. hook 설정을 끄거나 우회하지 않는다.
- 커버리지 명령과 기준선
- 테스트 개수. 기존 줄 "현재 6개"는 기반 단계 기준이며, 기존 줄 수정 금지 규칙 때문에 그대로 두고 새 섹션에 최신 개수를 적는다.

## 7. 빌더에게 맡기는 것

- 테스트 파일·Suite 구성, 테스트 이름과 표시 이름 언어
- 가짜 저장소 구현 세부 (Swift 6 동시성 대응 포함)
- 전체 테스트 스크립트와 hook 스크립트의 이름·구조, 단계별 실행 옵션 제공 여부
- 접근성 식별자 이름과 어느 요소에 달지 (텍스트로 찾을 수 있으면 생략 가능)
- `git commit` 판별 방식

## 8. 완료 기준 (verify)

1. 형식적 테스트 6개 삭제. 6개 모듈 + `PayLabUITests`에 6.2의 테스트가 있다.
2. 전체 테스트 스크립트 통과. Swift Testing 개수와 UI 테스트 개수를 출력에서 읽어 기록한다.
3. 전체 테스트를 3회 연속 실행해 모두 통과 (불안정 테스트 없음) **(제 판단)**.
4. hook 검증 **(제 판단)**:
   - 일부러 실패하는 테스트를 넣고 hook 스크립트에 `git commit` 입력을 주면 종료 코드 2.
   - 되돌린 뒤 같은 입력 → 종료 코드 0.
   - 이 세션에 hook이 실제로 걸리는지도 확인한다. 세션 중간에 추가한 hook은 바로 적용되지 않을 수 있다. 그 경우 새 세션에서 확인하도록 사용자에게 알린다.
5. 커버리지 리포트 출력, 기준선 기록.
6. Claude가 시뮬레이터에서 송금 성공·실패를 직접 확인하고 스크린샷을 남긴다.
7. `CLAUDE.md` 테스트 섹션 추가. 기존 줄 변경 없음 (시뮬레이터 이름 예외 제외).
8. 부록 A 갱신, 공유 노트 폴더에 인계 메모.
9. 이 브랜치에 커밋. main 병합 여부는 사용자에게 묻는다.

## 부록 A. 트랜잭션 세션용 발견 사항 (기록만, 고치지 않음)

코드를 읽으며 확인한 것. 구현 중 추가되면 여기에 덧붙인다.

- `TransferModel.submit()`에 진행 중 여부 확인이 없다. "보내기"를 연달아 누르면 송금 요청이 두 번 갈 수 있다 (`ConfirmView`가 탭마다 `Task`를 만든다).
- `submit()`은 `canProceed`를 다시 확인하지 않는다. 확인 화면에 들어온 뒤 금액이 바뀌는 경로는 지금 UI에는 없다.
- 실패 원인을 구분하지 않는다. 500, 404, 400, 네트워크 오류가 모두 `.failure` 하나로 표시된다.

구현 중 테스트로 고정한 현재 동작 (2026-11-10):

- 금액 `"-500"`은 500으로 읽힌다. `amount`가 숫자 외 문자를 모두 버리면서 부호도 버린다. 숫자 키패드라 지금 UI에서는 입력할 수 없고 붙여넣기로만 가능하다. (`TransferModelTests.amountParsing`)
- `FakeServer`는 출금 계좌·받는 사람 확인(404)을 금액 검사(400)보다 먼저 한다. 모르는 계좌 + 금액 0이면 404다. (`FakeServerTests.unknownAccountOrRecipientReturns404`)
- `failTransfers`가 켜지면 본문을 보기 전에 500을 돌려준다. 잔액은 그대로다. (`FakeServerTests.failTransfersReturns500BeforeAnyCheck`)
- 실패 주입 시 홈 잔액은 바뀌지 않는다. 앱 쪽에서 실패를 되돌릴 일이 없다. (`AppIntegrationTests.failedTransferKeepsHomeBalance`, `TransferFlowUITests.testTransferFailureKeepsHomeBalance`)
