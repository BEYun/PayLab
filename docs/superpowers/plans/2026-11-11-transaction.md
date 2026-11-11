# PayLab 송금 정합성 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 송금 한 건에 송금 키 하나를 붙여 돈이 정확히 한 번만 빠지게 하고, 결과를 보냈어요 / 송금 실패(이유) / 확인 중 셋으로 서버와 어긋나지 않게 보여 준다.

**Architecture:** Domain 프로토콜에 키를 받는 송금과 키로 찾는 조회를 넣는다. 가짜 서버는 키별 영수증을 저장해 같은 키는 다시 처리하지 않고, 실패 주입 3가지를 더 받는다. `TransferModel`이 송금 중 잠금, 오류 분류, 같은 키 재시도, 다시 확인을 맡고 뷰는 표시만 한다.

**Tech Stack:** Xcode 27.2, Swift 6 언어 모드, SwiftUI, Observation, Swift Testing, XCTest(UI 전용), Tuist 4.216.0

**Spec:** `docs/superpowers/specs/2026-11-11-transaction-design.md`

## Global Constraints

- Feature끼리 import 금지. Domain은 SwiftUI·네트워크 import 금지. 화면 로직은 `TransferModel`, 뷰는 표시만.
- 외부 라이브러리 추가 금지.
- 단위·통합: Swift Testing. XCTest는 UI 테스트에만. UI 테스트 고정 sleep 금지, `waitForExistence`.
- `FakeBackend.makeSession`(또는 `AppEnvironment.makeRepository`)을 부르는 테스트는 그 타깃의 `@Suite(.serialized)`에만.
- 테스트의 가짜 서버는 `FakeServer(latency: .zero, …)`. 모델 테스트의 재시도 대기는 `[.zero, .zero]`.
- 버그 수정은 재현 테스트 먼저: 연타 이중 송금(Task 3), 200 + 디코딩 실패 → 송금 실패(Task 3).
- 헤더 이름 `Idempotency-Key`. 재시도 대기 기본값 `[.milliseconds(500), .seconds(1)]`.
- 로그: `os.Logger`, subsystem `com.example.paylab`, 보간 값 `.public`. debug = 시작, info = 성공, error = 실패·ignored·비 2xx.
- 화면 문구 (그대로):
  - 확인 중: 제목 `확인 중이에요`, 설명 `송금이 처리됐는지 아직 몰라요. 잠시 후 다시 확인해 주세요.`, 버튼 `다시 확인`, `확인`
  - 실패 이유: 400 `금액을 확인해 주세요` · 404 `계좌나 받는 사람을 찾을 수 없어요` · 그 밖의 4xx `요청을 처리할 수 없어요` · 다시 확인 404 `보내지 않았어요`
  - 기존 `보냈어요`, `남은 잔액 …`, `송금 실패`, `확인` 유지
- `CLAUDE.md`: `## 트랜잭션` 섹션 신설. 기존 줄은 `--fail-transfer` 설명, 로그 표 `transfer` 행, 테스트 개수만 고친다.
- 커밋 금지: `*.xcodeproj`, `*.xcworkspace`, `Derived/`, `.build/`. 공개 저장소: 키·토큰·`/Users/...` 경로 금지.
- 커밋할 때마다 hook이 `scripts/test-all.sh` 전체를 돈다. 각 Task 끝에서 전체가 녹색이어야 한다.

## Review Focus

1. 송금 중 시트를 끌어내리거나 뒤로 가기 → 막혀야 한다. 모델 테스트로 못 잡는다 → Task 4 Claude 확인.
2. "다시 확인" 연타 → 조회 1번 → Task 3 `doubleRecheckQueriesOnce`.
3. 확인 중인데 창을 닫음 → 홈은 서버 잔액(이미 차감)을 보여야 한다 → Task 3 통합 `dropAlways…`의 홈 잔액 단언.
4. 확인 화면에서 뒤로 가 금액을 바꾼 뒤 송금 → 새 키라 서버가 422 없이 처리 → Task 1 `proceedToConfirmMakesNewKey`.
5. 처리 뒤 잔액이 줄어든 상태의 같은 키 재요청 → 400이 아니라 저장된 영수증 → Task 1 `replayBeatsBalanceCheck`.

## 공통 명령 (저장소 루트, `DEVELOPER_DIR` 설정한 셸)

| 이름 | 명령 | 통과 기준 |
|---|---|---|
| 모듈 테스트 `<T>` | `xcodebuild -workspace PayLab.xcworkspace -scheme PayLab -destination "platform=iOS Simulator,name=PayLab-$(git branch --show-current)" -derivedDataPath .build/DerivedData test -only-testing:<T> 2>&1 \| grep -E "✘\|✔ Test run\|error:\|TEST SUCCEEDED\|TEST FAILED"` | `** TEST SUCCEEDED **` |
| 전체 | `scripts/test-all.sh` | 마지막 줄 `ALL TESTS PASSED` |

---

### Task 0: 준비

- [ ] **Step 1:** `tuist generate --no-open`, 시뮬레이터 `PayLab-$(git branch --show-current)` 생성·부팅 (`CLAUDE.md` 명령). Expected: 오류 없음.
- [ ] **Step 2:** `scripts/test-all.sh`. Expected: `ALL TESTS PASSED` (기준선).
- [ ] **Step 3: Commit** 설계·계획 문서. hook이 전체 테스트를 다시 돈다.

```bash
git add docs/superpowers/specs/2026-11-11-transaction-design.md docs/superpowers/plans/2026-11-11-transaction.md
git commit -m "docs: 송금 정합성 설계·계획"
```

---

### Task 1: 송금 키 계약 (Domain → 가짜 서버 → 저장소 → 모델의 키 생성)

**Files:**
- Modify: `Modules/Domain/Sources/BankingRepository.swift`
- Modify: `Modules/DataKit/Sources/FakeServer.swift`, `FakeServerURLProtocol.swift`, `RemoteBankingRepository.swift`
- Modify: `Modules/TransferFeature/Sources/TransferModel.swift` (키 생성·전달만)
- Modify: `Modules/HomeFeature/Tests/StubBankingRepository.swift`, `Modules/TransferFeature/Tests/StubBankingRepository.swift`
- Test: `Modules/DataKit/Tests/FakeServerTests.swift`, `RemoteBankingRepositoryTests.swift`, `Modules/TransferFeature/Tests/TransferModelTests.swift`, `Modules/App/Tests/AppIntegrationTests.swift`

**Interfaces:**
- Produces (Domain):
  ```swift
  func transfer(_ request: TransferRequest, idempotencyKey: String) async throws -> TransferReceipt
  // 2xx 본문을 읽지 못하면 DecodingError를 던진다 (서버는 처리했다). 비 2xx는 BankingError.server.
  func findTransfer(idempotencyKey: String) async throws -> TransferReceipt?   // 404 → nil
  ```
  기존 `transfer(_:)`는 없앤다.
- Produces (DataKit): `FakeServer.handle(method: String, path: String, headers: [String: String] = [:], body: Data?)`. 반환은 아직 기존 튜플. `FakeServer.idempotencyKeyHeader = "Idempotency-Key"` (public static).
- Produces (TransferFeature): `public private(set) var idempotencyKey: String?` — `proceedToConfirm()`이 통과할 때마다 `UUID().uuidString`.

- [ ] **Step 1: 실패 테스트 — `FakeServerTests`**
  - 헬퍼 `postTransfer(_ body: Data?, key: String? = UUID().uuidString) -> (statusCode, body)`: 키가 있으면 `headers: [FakeServer.idempotencyKeyHeader: key]`. 기존 테스트는 이 헬퍼를 쓰므로 호출마다 새 키다 (같은 키·다른 본문 422 회피).
  - `missingKeyReturns400`: 유효 본문(acc-saving → rcp-1, 1,000), `key: nil` → 400, 잔액 50,000.
  - `sameKeySameBodyReplaysReceipt`: 같은 키 두 번 → 둘 다 200, 두 영수증 `==`, 잔액 49,000.
  - `sameKeyDifferentBodyReturns422`: 키 K로 1,000 → 200, 키 K로 2,000 → 422, 잔액 49,000.
  - `replayBeatsBalanceCheck`: 키 K로 30,000 → 200(잔액 20,000), 키 K로 30,000 다시 → 200 + 첫 영수증, 잔액 20,000.
  - `getTransferByKey`: K로 송금 뒤 `GET /transfers/K` → 200 + 같은 영수증. `GET /transfers/none` → 404.
  - 기존 `failTransfersReturns500BeforeAnyCheck`: 키 없이도 500 (판정 1이 2보다 먼저). 그대로 통과해야 한다.
- [ ] **Step 2: 실패 테스트 — `RemoteBankingRepositoryTests`** (직렬 Suite)
  - 기존 3개 송금 호출에 `idempotencyKey: UUID().uuidString`.
  - `sameKeyTransfersOnce`: 같은 키 두 번 → 영수증 `==`, `fetchAccounts`의 acc-main 1,249,000. (헤더가 안 가면 400이라 헤더 전송도 함께 검증된다.)
  - `findTransferReturnsReceiptOrNil`: 키 K 송금 뒤 `findTransfer(K) == receipt`, `findTransfer("none") == nil`.
- [ ] **Step 3: 실패 테스트 — `TransferModelTests`**
  - `proceedToConfirmMakesNewKey`: `moveToConfirm` → `key1 = try #require(model.idempotencyKey)`, `model.path.removeLast()`, `model.proceedToConfirm()` → `key2 != key1`.
  - `submitSuccess`: 저장소가 받은 키가 `model.idempotencyKey`와 같다 (`repository.transferCalls == [.init(request: …, idempotencyKey: key)]`).
  - 가짜 저장소(TransferFeature) 기록을 `struct TransferCall: Equatable { let request: TransferRequest; let idempotencyKey: String }` 배열 `transferCalls`로 바꾼다. `findTransfer`는 Task 3 전까지 `Issue.record` 후 throw.
  - HomeFeature 가짜 저장소: 두 새 메서드를 `Issue.record` + throw로 추가.
- [ ] **Step 4: 빌드 실패 확인** — 모듈 테스트 `DataKitTests`. Expected: 컴파일 오류(`idempotencyKey`, `headers` 없음).
- [ ] **Step 5: 구현**
  - `FakeServer.State`에 `var transfers: [String: (request: TransferRequest, receipt: TransferReceipt)]`.
  - `POST /transfers` 판정 순서 (설계 §6.2): failTransfers 500 → 키 없음 400 → 본문 400 → 같은 키(같은 본문 200 + 저장 영수증 / 다른 본문 422) → 404 → 금액 400 → 처리·저장 200. 4~7은 한 `withLock` 안.
  - `GET /transfers/<키>`: 경로가 `/transfers/`로 시작하면 나머지를 키로. 있으면 200, 없으면 404. `GET /transfers`(키 없음)는 기존대로 404.
  - `FakeServerURLProtocol`: `request.allHTTPHeaderFields ?? [:]`를 `handle`에 넘긴다.
  - `RemoteBankingRepository.send`에 `headers: [String: String] = [:]` 추가. `findTransfer`는 `send("GET", "transfers/\(key)")`를 부르고 `BankingError.server(statusCode: 404)`만 `nil`로 바꾼다.
  - `TransferModel`: `import Foundation`, `proceedToConfirm()` 통과 시 키 생성, `submit()`이 키를 넘긴다. 키가 nil이면 기존 `submit ignored` 줄에 `key=nil`을 붙여 무시. `submit start` 줄에 `key=<키>` 추가.
  - `AppIntegrationTests`: 송금 호출 2곳에 키 추가 (동작 변화 없음).
- [ ] **Step 6:** 모듈 테스트 `DataKitTests`, `TransferFeatureTests`, `HomeFeatureTests`, `PayLabTests`. Expected: 모두 SUCCEEDED.
- [ ] **Step 7: Commit** (hook 전체 테스트)

```bash
git add Modules
git commit -m "feat: 송금 키(Idempotency-Key)로 같은 송금 한 번만 처리, 키로 송금 조회"
```

---

### Task 2: 실패 주입 3가지

**Files:**
- Modify: `Modules/DataKit/Sources/FakeServer.swift`, `FakeServerURLProtocol.swift`
- Modify: `Modules/App/Sources/AppEnvironment.swift`
- Test: `Modules/DataKit/Tests/FakeServerTests.swift`, `RemoteBankingRepositoryTests.swift`, `Modules/App/Tests/AppIntegrationTests.swift`

**Interfaces:**
- Consumes: Task 1의 `handle(method:path:headers:body:)`, 키 헤더.
- Produces (DataKit):
  ```swift
  public enum TransferFault: String, Sendable, CaseIterable {
      case dropResponseOnce     // 처리 뒤 첫 200 응답만 연결 끊김
      case dropResponseAlways   // 처리 뒤 POST /transfers의 200 응답을 매번 끊음
      case garbleResponse       // 처리 뒤 200 + 읽을 수 없는 본문
  }
  FakeServer.init(latency: Duration = .milliseconds(300), failTransfers: Bool = false, transferFault: TransferFault? = nil)
  public struct FakeServer.Response: Sendable { public let statusCode: Int; public let body: Data; public let dropsConnection: Bool }
  ```
  `handle`의 반환형을 튜플에서 `Response`로 바꾼다. 기존 테스트의 `.statusCode`, `.body` 접근은 그대로 컴파일된다.
- Produces (App): `AppEnvironment.transferFaultArguments: [(argument: String, fault: TransferFault)]` =
  `--drop-transfer-response-once` → `.dropResponseOnce`, `--drop-transfer-response` → `.dropResponseAlways`, `--garble-transfer-response` → `.garbleResponse`. 둘 이상이면 배열 앞쪽이 이긴다.
  `static func transferFault(arguments: [String]) -> TransferFault?`.

- [ ] **Step 1: 실패 테스트 — `FakeServerTests`** (모두 키 K, acc-saving → rcp-1, 1,000)
  - `dropResponseOnceDropsFirstOnly`: 첫 POST `dropsConnection == true`, 잔액 49,000. 같은 키 두 번째 → `dropsConnection == false`, 200, 영수증이 `GET /transfers/K`와 같다. 잔액 49,000.
  - `dropResponseAlwaysDropsEveryReplay`: POST 두 번 모두 `dropsConnection == true`. `GET /transfers/K` → 200, `dropsConnection == false`. 잔액 49,000.
  - `garbleResponseCommitsWithUnreadableBody`: 200, `JSONDecoder().decode(TransferReceipt.self, …)`가 throw, 잔액 49,000.
  - `faultsDoNotTouchRejections`: `dropResponseAlways` 서버에 금액 0 → 400, `dropsConnection == false`.
- [ ] **Step 2: 실패 테스트 — `RemoteBankingRepositoryTests`**
  - `droppedResponseThrowsURLError`: `.dropResponseAlways` 서버 → `#expect(throws: URLError.self)`, 이어서 `findTransfer(K)`가 영수증을 돌려준다.
  - `garbledResponseThrowsDecodingError`: `.garbleResponse` → `#expect(throws: DecodingError.self)`.
- [ ] **Step 3: 실패 테스트 — `AppIntegrationTests`**
  - `transferFaultArguments` (매개변수): `[]` → nil, 각 인자 → 해당 fault, `["--drop-transfer-response", "--drop-transfer-response-once"]` → `.dropResponseOnce`.
- [ ] **Step 4:** 모듈 테스트 `DataKitTests`. Expected: 컴파일 오류.
- [ ] **Step 5: 구현**
  - `FakeServer`: fault는 `POST /transfers`의 200 응답(새 처리·재요청 모두)에만 적용. once는 `State`의 `didDropOnce` 플래그. garble 본문은 `Data("garbled".utf8)`.
  - `FakeServerURLProtocol`: `dropsConnection`이면 `client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))`만 부르고 끝.
  - `AppEnvironment.makeRepository`: `FakeServer(failTransfers:transferFault:)`. 기존 `launch failTransfers=` 줄은 그대로 두고 `log.info("launch transferFault=<rawValue|none>")` 한 줄 추가.
- [ ] **Step 6:** 모듈 테스트 `DataKitTests`, `PayLabTests`. Expected: SUCCEEDED.
- [ ] **Step 7: Commit**

```bash
git add Modules
git commit -m "feat: 가짜 서버 실패 주입 — 처리 후 응답 유실(한 번·매번), 깨진 응답"
```

---

### Task 3: `TransferModel` 정합성 — 송금 중 잠금, 결과 분류, 재시도, 다시 확인

**Files:**
- Modify: `Modules/TransferFeature/Sources/TransferModel.swift`, `ConfirmView.swift`, `ResultView.swift`, `TransferFlowView.swift`
- Modify: `Modules/TransferFeature/Tests/StubBankingRepository.swift`
- Test: `Modules/TransferFeature/Tests/TransferModelTests.swift`, `Modules/App/Tests/AppIntegrationTests.swift`, `Modules/App/UITests/TransferFlowUITests.swift`

**Interfaces:**
- Consumes: Task 1 프로토콜, Task 2 `TransferFault`.
- Produces (TransferFeature):
  ```swift
  public enum Outcome: Equatable {
      case success(TransferReceipt?)   // nil: 서버는 처리했지만 영수증을 읽지 못함
      case failure(FailureReason)
      case pending                      // 처리 여부 모름
  }
  public enum FailureReason: Equatable {
      case rejected(statusCode: Int)    // 4xx
      case notSent                      // 다시 확인 결과 404
      public var message: String        // Global Constraints의 문구
  }
  public private(set) var isSubmitting: Bool
  public private(set) var isChecking: Bool
  public init(fromAccount: Account, repository: any BankingRepository,
              retryDelays: [Duration] = [.milliseconds(500), .seconds(1)])
  public func recheck() async
  ```
- 가짜 저장소 (TransferFeature 테스트):
  ```swift
  init(recipients: Result<[Recipient], BankingError> = .success([]),
       transfers: [Result<TransferReceipt, any Error>] = [.failure(BankingError.server(statusCode: 500))],
       finds: [Result<TransferReceipt?, any Error>] = [.success(nil)],
       holdFirstTransfer: Bool = false, holdFirstFind: Bool = false)
  var transferCalls: [TransferCall] { get }
  var findKeys: [String] { get }
  func waitUntilHeld() async   // 멈춘 호출이 생길 때까지 대기
  func release()               // 멈춘 호출을 모두 풀어 줌
  ```
  결과 배열은 호출마다 앞에서 하나씩 쓰고, 다 쓰면 마지막을 반복한다. 멈춤은 첫 호출에만 걸린다 (수정 전 코드에서 두 번째 호출이 멈추지 않아 테스트가 끝나고 실패한다).

- [ ] **Step 1: 재현 테스트 먼저** — 가짜 저장소를 새 모양으로 바꾸고, 수정 전 모델에서도 컴파일되는 단언만 쓴다.
  - `doubleSubmitSendsOnce`: `holdFirstTransfer: true`, `transfers: [.success(receipt)]`. `let first = Task { await model.submit() }` → `await repository.waitUntilHeld()` → `await model.submit()` → `release()` → `await first.value` → `transferCalls.count == 1`.
  - `decodingErrorMeansSent`: `transfers: [.failure(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "test")))]` → `if case .success = model.outcome {} else { Issue.record(…) }`, 호출 1번.
- [ ] **Step 2:** 모듈 테스트 `TransferFeatureTests`. Expected: 두 테스트 FAIL (호출 2번, `.failure`). 결과를 기록한다. 모델 생성은 아직 `retryDelays` 없이.
- [ ] **Step 2a:** Step 4 구현 뒤 두 테스트를 강화한다: `doubleSubmitSendsOnce`에 `release()` 전 `#expect(model.isSubmitting)`, 끝에 `outcome == .success(receipt)`. `decodingErrorMeansSent`는 `outcome == .success(nil)`. 모든 모델 생성에 `retryDelays: [.zero, .zero]`.
- [ ] **Step 3: 나머지 실패 테스트**
  - `submitAfterResultIsIgnored`: 성공 뒤 `submit()` 다시 → 호출 1번.
  - `clientErrorIsRejectedWithoutRetry` (매개변수 400, 404, 422): `.failure(.rejected(statusCode: code))`, 호출 1번, `path.last == .result`, `isSubmitting == false`.
  - `unknownErrorRetriesWithSameKeyThenSucceeds`: `[500, URLError(.networkConnectionLost), .success(receipt)]` → `.success(receipt)`, 호출 3번, 키 종류 1개.
  - `unknownErrorThreeTimesBecomesPending` (기존 `submitFailure` 대체): 기본 500 → `.pending`, 호출 3번, `path.last == .result`, `isSubmitting == false`.
  - `otherErrorIsTreatedAsUnknown`: `CancellationError()` → `.pending`, 호출 3번.
  - `recheck` (매개변수, 확인 중 상태에서): `.success(receipt)` → `.success(receipt)` · `.success(nil)` → `.failure(.notSent)` · DecodingError → `.success(nil)` · `BankingError.server(500)` → `.pending`. 모두 `findKeys == [key]`, `transferCalls.count == 3`(새 송금 없음), `isChecking == false`.
  - `doubleRecheckQueriesOnce`: `holdFirstFind: true`. 첫 `recheck`를 Task로 → `waitUntilHeld` → 두 번째 `recheck` → `release` → `findKeys.count == 1`.
  - `recheckIgnoredUnlessPending`: 성공 상태에서 `recheck()` → `findKeys.isEmpty`.
  - `failureReasonMessages` (매개변수): `.rejected(400)`, `.rejected(404)`, `.rejected(422)`, `.notSent` → Global Constraints 문구.
  - 기존 `submitSuccess`·`submitWithoutRecipientDoesNothing`은 유지 (`.success(receipt)`는 옵셔널 승격으로 그대로 비교).
- [ ] **Step 4: 구현 — `TransferModel`**
  - `submit()`: `isSubmitting`이면 `submit ignored inFlight key=…`, `outcome != nil`이면 `submit ignored done key=…`(둘 다 error) 후 return. 그다음 기존 recipient·amount·key guard.
  - 분류: `DecodingError` → `.success(nil)` (`submit ok unreadable key=…`, error) · `BankingError.server(400..<500)` → `.failure(.rejected)` (`submit rejected status=…`, error) · 그 밖의 모든 오류 → 모름.
  - 모름: `retryDelays` 개수만큼 같은 키로 재시도 (`submit retry attempt=<n> after=<ms>ms: <오류>`, error, `try? await Task.sleep(for:)`), 다 쓰면 `.pending` (`submit pending key=… attempts=<n>`, error).
  - 끝나면 `isSubmitting = false`, `path.append(.result)`. 기존 `submit failed` 줄은 없어진다.
  - `recheck()`: `outcome == .pending && !isChecking`이 아니면 `recheck ignored`(error) 후 return. `recheck start key=`(debug) → 찾음 `recheck ok transferID=… balanceAfter=…`(info) · nil `recheck notFound key=`(error) · DecodingError `recheck ok unreadable`(error) · 그 밖 `recheck failed: …`(error, `.pending` 유지). 재시도 없음.
- [ ] **Step 5: 구현 — 뷰**
  - `ConfirmView`: `PrimaryButton("보내기", isEnabled: !model.isSubmitting)`, `.navigationBarBackButtonHidden(model.isSubmitting)`.
  - `TransferFlowView`: `NavigationStack`에 `.interactiveDismissDisabled(model.isSubmitting)`.
  - `ResultView`: `.success(receipt)` → `보냈어요` + receipt가 있을 때만 `남은 잔액 …` · `.failure(reason)` → `송금 실패` + `reason.message` · `.pending` → 확인 중 문구 + `PrimaryButton("다시 확인", isEnabled: !model.isChecking) { Task { await model.recheck() } }` · `nil` → 빈 화면. `확인` 버튼은 항상.
- [ ] **Step 6: 통합 — `AppIntegrationTests`** (헬퍼가 `FakeServer`를 받고, `TransferModel(…, retryDelays: [.zero, .zero])`)
  - `successfulTransferShowsOnHome`: 패턴을 `case .success(let receipt?)`로.
  - `failTransferEndsNotSentAndKeepsHomeBalance` (기존 `failedTransferKeepsHomeBalance` 대체): `.pending` → `recheck()` → `.failure(.notSent)`, 홈 1,250,000.
  - `dropOnceRetriesToSuccess`: `.success(receipt?)`, 홈 1,249,000.
  - `dropAlwaysPendingThenRecheckFindsTransfer`: `.pending` → **이 시점에 `home.load()` → 1,249,000** (Review Focus 3) → `recheck()` → `.success(receipt?)`.
  - `garbleShowsSentWithoutReceipt`: `.success(nil)`, 홈 1,249,000.
- [ ] **Step 7: UI — 기존 실패 테스트 갱신** `testTransferFailureKeepsHomeBalance`: `확인 중이에요`(timeout 10) → `다시 확인` 탭 → `송금 실패`, `보내지 않았어요` → `확인` → 기존 잔액 단언.
- [ ] **Step 8:** `scripts/test-all.sh`. Expected: `ALL TESTS PASSED`.
- [ ] **Step 9: Commit**

```bash
git add Modules
git commit -m "fix: 송금 중복 제출 방지, 결과 분류(보냈어요·실패·확인 중), 같은 키 재시도와 다시 확인"
```

---

### Task 4: UI 테스트 추가, 시뮬레이터 확인, 문서

**Files:**
- Test: `Modules/App/UITests/TransferFlowUITests.swift`
- Modify: `CLAUDE.md`

- [ ] **Step 1: UI 테스트** `testDroppedResponseRecheckFindsTransfer`: `launchArguments = ["--drop-transfer-response"]` → 송금 → `확인 중이에요`(timeout 10) → `다시 확인` → `보냈어요` → `확인` → `1,249,000원`.
- [ ] **Step 2:** `xcodebuild … -scheme PayLabUITests … test`. Expected: 3개 통과.
- [ ] **Step 3: Claude 확인** — 앱 설치 후 실행 인자별로 실행, `.build/screens/`에 스크린샷.
  - 일반: 보냈어요.
  - `--fail-transfer`: 확인 중 → 다시 확인 → 송금 실패 · 보내지 않았어요.
  - `--drop-transfer-response-once`: 보냈어요. 로그에 `submit retry attempt=1`, `request POST /transfers` 2줄.
  - `--drop-transfer-response`: 확인 중 → 다시 확인 → 보냈어요. **송금 중(약 2초)에 시트 끌어내리기·뒤로 가기가 안 되는지** (Review Focus 1).
  - `--garble-transfer-response`: 보냈어요, 남은 잔액 줄 없음.
  - "보내기" 연타: 로그에 `request POST /transfers` 1줄, `submit ignored inFlight`.
- [ ] **Step 4: `CLAUDE.md`**
  - 명령 블록 `--fail-transfer` 주석을 `# 처리 전 500 주입 (확인 중 → 다시 확인 → 송금 실패)`로.
  - 로그 표 `transfer` 행: `submit start key=…` · `submit ignored inFlight/done` · `submit retry attempt=<n> after=<ms>ms` · `submit ok` / `submit ok unreadable` / `submit rejected status=` / `submit pending attempts=` · `recheck start/ok/notFound/failed/ignored`.
  - 테스트 개수 줄 갱신 (Swift Testing·UI·hook 실측).
  - `## 트랜잭션` 신설: 설계 문서 링크, 송금 키 규칙, 서버 판정 순서 요약, 결과 분류 표, 실패 주입 인자 4개와 기대 화면, `launch transferFault=` 로그, 재현 명령.
- [ ] **Step 5: Commit**

```bash
git add Modules/App/UITests CLAUDE.md
git commit -m "test: 응답 유실 UI 테스트, CLAUDE.md 트랜잭션 섹션"
```

### Task 5: 마무리

- [ ] **Step 1:** 브랜치 전체 기록 검사: `git log -p origin/main..HEAD | grep -nE "/Users/|sk-|ghp_|token"`. Expected: 결과 없음 (설계 문서의 단어 "token" 등은 눈으로 확인).
- [ ] **Step 2:** 공유 노트 폴더에 `transaction-handover.md` (남은 것, 성능 세션 참고).
- [ ] **Step 3:** push·PR은 사용자 확인 후.
