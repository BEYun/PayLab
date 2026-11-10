# PayLab 기반 단계 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 홈·송금 흐름이 동작하는 모듈화 SwiftUI 샘플 앱 PayLab을 만든다. 이후 주제별 세션이 쓸 git 저장소, Tuist 프로젝트, 프로젝트 `CLAUDE.md`도 함께 만든다.

**Architecture:** Tuist 단일 `Project.swift`에 앱 1개와 정적 프레임워크 모듈 5개(Domain, DataKit, DesignSystem, HomeFeature, TransferFeature), 모듈별 테스트 타깃을 정의한다. 앱은 실제 `URLSession`으로 요청하고, `URLProtocol`이 가로채 메모리 속 가짜 서버가 JSON으로 응답한다. App이 DataKit 구현체를 만들어 Feature에 주입하고, Feature끼리는 서로 모른다.

**Tech Stack:** Xcode 27.2, Swift 6 언어 모드, SwiftUI, iOS 18+, Tuist 4 (Homebrew cask), Swift Testing, `Synchronization.Mutex`

**Spec:** `docs/superpowers/specs/2026-11-06-foundation-design.md`

## Global Constraints

- 모든 타깃: 최소 iOS `18.0`, `SWIFT_VERSION = 6.0`.
- 앱 이름 `PayLab`, 번들 ID `com.example.paylab`. 토스 로고·이름·브랜드 자산 사용 금지.
- 외부 라이브러리 의존 없음.
- 설계의 Data 모듈 이름은 `DataKit`으로 쓴다. `Data`는 Foundation 타입 이름과 겹쳐 `import` 시 충돌한다.
- Feature 간 직접 의존 금지. Domain은 Foundation만 import (SwiftUI·네트워크 금지).
- 화면 로직은 `@Observable` 모델에 둔다. 뷰는 표시와 입력 전달만.
- 금액은 `Int`, 원 단위. 화면 문구는 한국어.
- 커밋 금지: `*.xcodeproj`, `*.xcworkspace`, `Derived/`, `.build/`.
- **비목표 미리 구현 금지:** 로깅, 디버그 메뉴, 실제 테스트, CI, 실패 처리·재시도·중복 송금 방지·멱등성, 성능 측정. 예를 들어 "보내기" 연타 방지도 넣지 않는다 (트랜잭션 세션 몫).
- **테스트 타깃마다 형식적 테스트 1개만** 둔다. 사용자 전역 CLAUDE.md의 "기능 추가 시 테스트" 규칙보다 승인된 설계가 우선한다. 실제 테스트는 테스트 세션 몫이고, 이 계획의 검증은 빌드·형식적 테스트·시뮬레이터 확인으로 한다.
- 명령은 저장소 루트 기준 상대 경로만 쓴다 (git worktree 호환).
- `xcode-select -p`가 `/Library/Developer/CommandLineTools`이면 셸마다 먼저 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## 공통 명령

모든 task가 아래 이름으로 참조한다.

| 이름 | 명령 | 통과 기준 |
|---|---|---|
| **생성** | `tuist generate --no-open` | 오류 없이 종료, `PayLab.xcworkspace` 생성 |
| **빌드** | `xcodebuild -workspace PayLab.xcworkspace -scheme PayLab -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' -derivedDataPath .build/DerivedData build` | `** BUILD SUCCEEDED **` |
| **테스트** | 빌드 명령에서 마지막 `build`를 `test`로 | `** TEST SUCCEEDED **` |
| **실행** | `xcrun simctl boot "iPhone 18 Pro" 2>/dev/null; xcrun simctl install booted .build/DerivedData/Build/Products/Debug-iphonesimulator/PayLab.app && xcrun simctl launch --terminate-running-process booted com.example.paylab` | 프로세스 ID 출력 |
| **실패 주입 실행** | 실행 명령 끝에 ` --fail-transfer` | 프로세스 ID 출력 |
| **스크린샷** | `mkdir -p .build/screens && xcrun simctl io booted screenshot .build/screens/<이름>.png` | 파일 생성 |

시뮬레이터 탭·입력은 iOS Simulator 제어 도구(`mcp__Claude_Code_iOS_Simulator__control`)로 한다.

## Review Focus

설계가 암시하지만 형식적 테스트로는 잡히지 않는 입력. Task 7의 시뮬레이터 확인 항목으로 고정한다.

1. 금액 칸에 숫자 외 문자(`1,000원`, 공백) 입력 → 숫자만 인식해 1000으로 처리, "다음" 활성.
2. Int 범위를 넘는 긴 숫자(`99999999999999999999`) → 크래시 없이 "다음" 비활성.
3. 잔액과 정확히 같은 금액 → 허용, 송금 후 잔액 `0원`. 잔액+1, `0` → 비활성.
4. 송금 실패 후 → 출금 계좌 잔액 그대로 (서버가 차감하지 않음).
5. 송금 시트를 쓸어내려 닫음 → 홈 잔액 다시 불러옴. 다시 열면 받는 사람 선택부터 시작.

---

### Task 1: 저장소와 빌드 뼈대

**Files:**
- Create: `.gitignore`, `Tuist.swift`, `Project.swift`, `CLAUDE.md`
- Create: `Modules/App/Sources/PayLabApp.swift`
- Test: `Modules/App/Tests/PayLabSmokeTests.swift`
- 기존 포함: `docs/superpowers/specs/2026-11-06-foundation-design.md`, 이 계획 파일

**Interfaces:**
- Produces: `Project.swift`의 `modules` 목록. 이후 task는 여기에 `(name:, dependencies:)` 한 줄을 추가하고 `Modules/<name>/Sources`, `Modules/<name>/Tests`를 만든다. 스킴 `PayLab`이 앱과 모든 테스트 타깃을 포함한다.

- [ ] **Step 1: 도구 준비**

Run: `xcode-select -p` → CommandLineTools면 `export DEVELOPER_DIR=...` (Global Constraints).
Run: `brew install --cask tuist && tuist version`
Expected: `4.`으로 시작하는 버전 출력

- [ ] **Step 2: git 초기화**

Run: `git init -b main`

- [ ] **Step 3: `.gitignore` 작성**

```gitignore
# Tuist 생성물
*.xcodeproj
*.xcworkspace
Derived/
# 빌드 산출물
.build/
DerivedData/
# macOS
.DS_Store
```

- [ ] **Step 4: `Tuist.swift` 작성**

기본값만 쓰는 최소 매니페스트 (`import ProjectDescription` + 기본 `Tuist` 설정). 설치된 Tuist 버전의 형식이 다르면 `tuist init`으로 만든 임시 폴더의 `Tuist.swift`를 참고한다.

- [ ] **Step 5: `Project.swift` 작성**

아래 구조와 값을 그대로 쓴다. Tuist API 이름이 설치 버전과 다르면 같은 의미로 맞춘다.

```swift
import ProjectDescription

let bundleID = "com.example.paylab"
let deploymentTargets: DeploymentTargets = .iOS("18.0")
let settings: Settings = .settings(base: ["SWIFT_VERSION": "6.0"])

/// 모듈 = 정적 프레임워크 + 테스트 타깃. 경로: Modules/<name>/Sources, Modules/<name>/Tests
func module(_ name: String, dependencies: [String]) -> [Target] {
    [
        .target(name: name, destinations: .iOS, product: .staticFramework,
                bundleId: "\(bundleID).\(name)", deploymentTargets: deploymentTargets,
                sources: ["Modules/\(name)/Sources/**"],
                dependencies: dependencies.map { .target(name: $0) }, settings: settings),
        .target(name: "\(name)Tests", destinations: .iOS, product: .unitTests,
                bundleId: "\(bundleID).\(name)Tests", deploymentTargets: deploymentTargets,
                sources: ["Modules/\(name)/Tests/**"],
                dependencies: [.target(name: name)], settings: settings),
    ]
}

// 모듈 목록. 이후 task가 한 줄씩 추가한다.
let modules: [(name: String, dependencies: [String])] = []

let app: Target = .target(
    name: "PayLab", destinations: .iOS, product: .app, bundleId: bundleID,
    deploymentTargets: deploymentTargets,
    infoPlist: .extendingDefault(with: ["UILaunchScreen": [:], "CFBundleDisplayName": "PayLab"]),
    sources: ["Modules/App/Sources/**"],
    dependencies: modules.map { .target(name: $0.name) }, settings: settings)

let appTests: Target = .target(
    name: "PayLabTests", destinations: .iOS, product: .unitTests, bundleId: "\(bundleID).tests",
    deploymentTargets: deploymentTargets, sources: ["Modules/App/Tests/**"],
    dependencies: [.target(name: "PayLab")], settings: settings)

let testTargets = ["PayLabTests"] + modules.map { "\($0.name)Tests" }

let project = Project(
    name: "PayLab",
    options: .options(automaticSchemesOptions: .disabled),
    targets: [app, appTests] + modules.flatMap { module($0.name, dependencies: $0.dependencies) },
    schemes: [
        .scheme(name: "PayLab",
                buildAction: .buildAction(targets: ["PayLab"]),
                testAction: .targets(testTargets.map { .testableTarget(target: .target($0)) }),
                runAction: .runAction(executable: "PayLab")),
    ]
)
```

- [ ] **Step 6: 앱 진입점 `PayLabApp.swift` 작성**

`@main struct PayLabApp: App` — `WindowGroup { Text("PayLab") }`. Task 7에서 교체한다.

- [ ] **Step 7: 형식적 테스트 작성**

```swift
import Testing
@testable import PayLab

@Test func appModuleLoads() { #expect(Bool(true)) }
```

이후 모든 모듈의 형식적 테스트는 같은 모양이다: `@testable import <Module>` + `@Test func <module>ModuleLoads()`.

- [ ] **Step 8: 프로젝트 `CLAUDE.md` 작성**

아래 내용을 그대로 쓴다.

````markdown
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
tuist generate --no-open   # Project.swift 수정 후, 새 worktree에서 매번
xcodebuild -workspace PayLab.xcworkspace -scheme PayLab -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' -derivedDataPath .build/DerivedData build
xcodebuild -workspace PayLab.xcworkspace -scheme PayLab -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' -derivedDataPath .build/DerivedData test
xcrun simctl boot "iPhone 18 Pro" 2>/dev/null; xcrun simctl install booted .build/DerivedData/Build/Products/Debug-iphonesimulator/PayLab.app
xcrun simctl launch --terminate-running-process booted com.example.paylab                   # 일반 실행
xcrun simctl launch --terminate-running-process booted com.example.paylab --fail-transfer   # 송금 실패 주입
```

## 금지
- `*.xcodeproj`, `*.xcworkspace`, `Derived/`, `.build/` 커밋 금지
- 외부 라이브러리 추가는 해당 주제 세션에서 사용자 확인 후
````

- [ ] **Step 9: 검증**

Run: **생성** → **빌드** → **테스트** → **실행** → **스크린샷**(`task1`)
Expected: 각 통과 기준 충족. 테스트 1개 통과. 스크린샷 화면에 `PayLab` 글자.

- [ ] **Step 10: 생성물이 추적되지 않는지 확인**

Run: `git status --porcelain | grep -E 'xcodeproj|xcworkspace|Derived|\.build'`
Expected: 출력 없음

- [ ] **Step 11: Commit**

```bash
git add .gitignore Tuist.swift Project.swift CLAUDE.md Modules docs
git commit -m "chore: PayLab 저장소와 Tuist 빌드 뼈대"
```

---

### Task 2: Domain 모듈

**Files:**
- Modify: `Project.swift` — `modules`에 `(name: "Domain", dependencies: [])`
- Create: `Modules/Domain/Sources/Models.swift`, `Modules/Domain/Sources/BankingRepository.swift`, `Modules/Domain/Sources/TransferRule.swift`
- Test: `Modules/Domain/Tests/DomainSmokeTests.swift`

**Interfaces:**
- Produces (모든 struct에 `public` memberwise init을 둔다):

```swift
public struct Account: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String          // "PayLab 통장"
    public let maskedNumber: String  // "3333-01-****21"
    public var balance: Int          // 원
}
public struct Recipient: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let bankName: String
    public let maskedNumber: String
}
public struct TransferRequest: Hashable, Codable, Sendable {
    public let fromAccountID: String
    public let recipientID: String
    public let amount: Int
}
public struct TransferReceipt: Hashable, Codable, Sendable {
    public let transferID: String
    public let amount: Int
    public let balanceAfter: Int
}
public enum BankingError: Error, Equatable, Sendable {
    case server(statusCode: Int)
}
public protocol BankingRepository: Sendable {
    func fetchAccounts() async throws -> [Account]
    func fetchRecipients() async throws -> [Recipient]
    func transfer(_ request: TransferRequest) async throws -> TransferReceipt
}
public enum TransferRule {
    /// amount > 0 && amount <= balance
    public static func isValidAmount(_ amount: Int, balance: Int) -> Bool
}
```

- [ ] **Step 1: `Project.swift`에 Domain 추가, 위 타입 구현**
- [ ] **Step 2: 형식적 테스트 작성** — `@testable import Domain`, `@Test func domainModuleLoads()`
- [ ] **Step 3: 검증**

Run: **생성** → **빌드** → **테스트**
Expected: 테스트 2개 통과 (PayLabTests, DomainTests)

- [ ] **Step 4: Commit**

```bash
git add Project.swift Modules/Domain
git commit -m "feat: Domain 모델과 BankingRepository 프로토콜"
```

---

### Task 3: DataKit 모듈 — 가짜 서버

**Files:**
- Modify: `Project.swift` — `modules`에 `(name: "DataKit", dependencies: ["Domain"])`
- Create: `Modules/DataKit/Sources/FakeServer.swift`, `Modules/DataKit/Sources/FakeServerURLProtocol.swift`, `Modules/DataKit/Sources/FakeBackend.swift`, `Modules/DataKit/Sources/RemoteBankingRepository.swift`
- Test: `Modules/DataKit/Tests/DataKitSmokeTests.swift`

**Interfaces:**
- Consumes: Task 2의 `Account`, `Recipient`, `TransferRequest`, `TransferReceipt`, `BankingError`, `BankingRepository`, `TransferRule`
- Produces:

```swift
public final class FakeServer: Sendable {
    public let latency: Duration
    public let failTransfers: Bool
    public init(latency: Duration = .milliseconds(300), failTransfers: Bool = false)
    /// 지연 없이 요청 하나를 처리. 상태는 Mutex로 보호.
    public func handle(method: String, path: String, body: Data?) -> (statusCode: Int, body: Data)
}
public enum FakeBackend {
    public static let baseURL: URL   // https://api.paylab.example
    /// server를 FakeServerURLProtocol에 등록하고, 그 프로토콜만 쓰는 URLSession을 반환
    public static func makeSession(server: FakeServer) -> URLSession
}
public struct RemoteBankingRepository: BankingRepository {
    public init(session: URLSession, baseURL: URL = FakeBackend.baseURL)
}
```

**API 계약** (JSON은 `JSONEncoder`/`JSONDecoder` 기본 설정, 키는 프로퍼티 이름 그대로):

| 메서드 | 경로 | 요청 본문 | 응답 |
|---|---|---|---|
| GET | `/accounts` | — | 200 `[Account]` |
| GET | `/recipients` | — | 200 `[Recipient]` |
| POST | `/transfers` | `TransferRequest` | 아래 순서로 판정 |

`POST /transfers` 판정 순서:
1. `failTransfers == true` → 500, 상태 변경 없음
2. 출금 계좌나 받는 사람 id 없음 → 404
3. `TransferRule.isValidAmount` 거짓 → 400
4. 그 외 → 출금 계좌 잔액 차감, 200 `TransferReceipt`

그 밖의 경로·메서드는 404. 200이 아닌 응답의 본문은 `{}`.

**초기 데이터** (메모리에만 존재, 앱 재시작 시 초기화):

| id | name | maskedNumber | balance |
|---|---|---|---|
| `acc-main` | PayLab 통장 | 3333-01-****21 | 1250000 |
| `acc-living` | 생활비 통장 | 3333-02-****58 | 320000 |
| `acc-saving` | 비상금 통장 | 3333-03-****07 | 50000 |

| id | name | bankName | maskedNumber |
|---|---|---|---|
| `rcp-1` | 김하늘 | 국민은행 | 123-45-****78 |
| `rcp-2` | 이도윤 | 신한은행 | 110-23-****56 |
| `rcp-3` | 박서연 | 우리은행 | 1002-3-****89 |

- [ ] **Step 1: `Project.swift`에 DataKit 추가, `FakeServer` 구현**

상태(계좌·받는 사람 배열)는 `Synchronization.Mutex`로 보호한다.

- [ ] **Step 2: `FakeServerURLProtocol` 구현 (internal)**

- `final class FakeServerURLProtocol: URLProtocol, @unchecked Sendable`
- 등록된 서버는 `static let` + `Mutex<FakeServer?>`로 보관한다 (Swift 6에서 전역 가변 상태 금지).
- `canInit`: host가 `api.paylab.example`일 때만 true.
- `startLoading`: `server.latency`만큼 뒤에 `handle` 결과로 `HTTPURLResponse` → 본문 → 완료를 client에 전달.
- **주의:** POST 본문은 `request.httpBody`가 nil일 수 있다. nil이면 `httpBodyStream`에서 읽는다.

- [ ] **Step 3: `FakeBackend`, `RemoteBankingRepository` 구현**

`RemoteBankingRepository`는 `session.data(for:)`를 쓴다. 상태 코드가 200..<300이 아니면 `BankingError.server(statusCode:)`를 던진다. POST에는 `Content-Type: application/json`을 붙인다.

- [ ] **Step 4: 형식적 테스트 작성** — `@testable import DataKit`, `@Test func dataKitModuleLoads()`
- [ ] **Step 5: 검증**

Run: **생성** → **빌드** → **테스트**
Expected: 테스트 3개 통과. 동작 확인은 Task 7 시뮬레이터 검증에서 한다.

- [ ] **Step 6: Commit**

```bash
git add Project.swift Modules/DataKit
git commit -m "feat: URLProtocol 기반 가짜 서버와 RemoteBankingRepository"
```

---

### Task 4: DesignSystem 모듈

**Files:**
- Modify: `Project.swift` — `modules`에 `(name: "DesignSystem", dependencies: [])`
- Create: `Modules/DesignSystem/Sources/Tokens.swift`, `Modules/DesignSystem/Sources/PrimaryButton.swift`, `Modules/DesignSystem/Sources/WonFormatter.swift`
- Test: `Modules/DesignSystem/Tests/DesignSystemSmokeTests.swift`

**Interfaces:**
- Produces:

```swift
public enum PayColor {
    public static let primary: Color        // Color(red: 0.31, green: 0.27, blue: 0.90)
    public static let background: Color     // Color(.systemBackground)
    public static let surface: Color        // Color(.secondarySystemBackground)
    public static let textPrimary: Color    // .primary
    public static let textSecondary: Color  // .secondary
    public static let danger: Color         // .red
}
public enum PaySpacing { public static let small: CGFloat = 8; public static let medium: CGFloat = 16; public static let large: CGFloat = 24 }
public enum PayFont {
    public static let title: Font    // .system(size: 26, weight: .bold)
    public static let body: Font     // .system(size: 17)
    public static let caption: Font  // .system(size: 14)
}
/// 화면 너비를 채우는 기본 버튼. 비활성이면 회색 배경, 탭 무시.
public struct PrimaryButton: View {
    public init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void)
}
/// 1250000 → "1,250,000원". ko_KR 숫자 형식 + "원".
public func formatWon(_ amount: Int) -> String
```

- [ ] **Step 1: `Project.swift`에 DesignSystem 추가, 위 타입 구현** (`PrimaryButton`에 `#Preview` 하나)
- [ ] **Step 2: 형식적 테스트 작성** — `@testable import DesignSystem`, `@Test func designSystemModuleLoads()`
- [ ] **Step 3: 검증**

Run: **생성** → **빌드** → **테스트**
Expected: 테스트 4개 통과

- [ ] **Step 4: Commit**

```bash
git add Project.swift Modules/DesignSystem
git commit -m "feat: DesignSystem 토큰, PrimaryButton, formatWon"
```

---

### Task 5: HomeFeature 모듈

**Files:**
- Modify: `Project.swift` — `modules`에 `(name: "HomeFeature", dependencies: ["Domain", "DesignSystem"])`
- Create: `Modules/HomeFeature/Sources/HomeModel.swift`, `Modules/HomeFeature/Sources/HomeView.swift`, `Modules/HomeFeature/Sources/AccountRow.swift`
- Test: `Modules/HomeFeature/Tests/HomeFeatureSmokeTests.swift`

**Interfaces:**
- Consumes: `Account`, `BankingRepository` (Task 2), `PayColor`·`PaySpacing`·`PayFont`·`formatWon` (Task 4)
- Produces:

```swift
@MainActor @Observable
public final class HomeModel {
    public private(set) var accounts: [Account] = []
    public private(set) var isLoading = false
    public init(repository: any BankingRepository)
    /// fetchAccounts 성공 시 accounts 교체. 실패 시 기존 accounts 유지 (실패 처리는 비목표).
    public func load() async
}
public struct HomeView: View {
    public init(model: HomeModel, onTransfer: @escaping (Account) -> Void)
}
```

화면: 제목 `내 계좌`. 계좌마다 `AccountRow` — 이름, `maskedNumber`, `formatWon(balance)`, 오른쪽 `송금` 버튼 → `onTransfer(account)`. `accounts`가 비어 있고 `isLoading`이면 `ProgressView`. `.task { await model.load() }`로 첫 로드.

- [ ] **Step 1: `Project.swift`에 HomeFeature 추가, 위 타입 구현**
- [ ] **Step 2: 형식적 테스트 작성** — `@testable import HomeFeature`, `@Test func homeFeatureModuleLoads()`
- [ ] **Step 3: 검증**

Run: **생성** → **빌드** → **테스트**
Expected: 테스트 5개 통과

- [ ] **Step 4: Commit**

```bash
git add Project.swift Modules/HomeFeature
git commit -m "feat: 홈 계좌 목록 화면"
```

---

### Task 6: TransferFeature 모듈

**Files:**
- Modify: `Project.swift` — `modules`에 `(name: "TransferFeature", dependencies: ["Domain", "DesignSystem"])`
- Create: `Modules/TransferFeature/Sources/TransferModel.swift`, `TransferFlowView.swift`, `RecipientListView.swift`, `AmountInputView.swift`, `ConfirmView.swift`, `ResultView.swift` (모두 `Modules/TransferFeature/Sources/`)
- Test: `Modules/TransferFeature/Tests/TransferFeatureSmokeTests.swift`

**Interfaces:**
- Consumes: `Account`, `Recipient`, `TransferRequest`, `TransferReceipt`, `BankingRepository`, `TransferRule` (Task 2), DesignSystem 전부 (Task 4)
- Produces:

```swift
@MainActor @Observable
public final class TransferModel {
    public enum Step: Hashable { case amount, confirm, result }
    public enum Outcome: Equatable { case success(TransferReceipt), failure }
    public let fromAccount: Account
    public private(set) var recipients: [Recipient] = []
    public private(set) var selectedRecipient: Recipient?
    public var amountText = ""
    public var path: [Step] = []
    public private(set) var outcome: Outcome?
    public init(fromAccount: Account, repository: any BankingRepository)
    /// amountText에서 숫자만 남겨 Int로. 비었거나 Int 범위를 넘으면 nil.
    public var amount: Int? { get }
    /// amount가 있고 TransferRule.isValidAmount(amount, balance: fromAccount.balance)
    public var canProceed: Bool { get }
    public func loadRecipients() async     // 실패 시 빈 목록 유지
    public func select(_ recipient: Recipient)   // selectedRecipient 설정, path = [.amount]
    public func proceedToConfirm()         // canProceed일 때만 path.append(.confirm)
    public func submit() async             // transfer 성공 → .success, 어떤 오류든 → .failure. 그다음 path.append(.result)
}
public struct TransferFlowView: View {
    /// model은 @State로 보관한다 (부모가 다시 그려져도 진행 상태 유지).
    public init(model: TransferModel, onFinish: @escaping () -> Void)
}
```

화면 (`NavigationStack(path: $model.path)`, 루트 = 받는 사람 선택):

| 화면 | 문구·동작 |
|---|---|
| RecipientListView | 제목 `누구에게 보낼까요?`. 행: 이름, 은행, `maskedNumber`. 탭 → `select`. `.task { await model.loadRecipients() }`. 툴바 `닫기` → `onFinish()` |
| AmountInputView | 제목 `얼마를 보낼까요?`. `출금: {fromAccount.name} · 잔액 {formatWon}`. `TextField`(`.keyboardType(.numberPad)`) ↔ `amountText`. `PrimaryButton("다음", isEnabled: canProceed)` → `proceedToConfirm()` |
| ConfirmView | `{받는 사람 이름}님에게 {formatWon(amount)}을 보낼까요?`, 출금 계좌 이름. `PrimaryButton("보내기")` → `submit()`. 연타 방지 없음 (비목표) |
| ResultView | 성공: `보냈어요` + `남은 잔액 {formatWon(balanceAfter)}`. 실패: `송금 실패` (`PayColor.danger`). 뒤로 버튼 숨김. `PrimaryButton("확인")` → `onFinish()` |

- [ ] **Step 1: `Project.swift`에 TransferFeature 추가, `TransferModel` 구현**
- [ ] **Step 2: 화면 4개와 `TransferFlowView` 구현**
- [ ] **Step 3: 형식적 테스트 작성** — `@testable import TransferFeature`, `@Test func transferFeatureModuleLoads()`
- [ ] **Step 4: 검증**

Run: **생성** → **빌드** → **테스트**
Expected: 테스트 6개 통과

- [ ] **Step 5: Commit**

```bash
git add Project.swift Modules/TransferFeature
git commit -m "feat: 송금 흐름 화면과 TransferModel"
```

---

### Task 7: App 조립과 시뮬레이터 검증

**Files:**
- Modify: `Modules/App/Sources/PayLabApp.swift`
- Create: `Modules/App/Sources/AppEnvironment.swift`, `Modules/App/Sources/RootView.swift`

**Interfaces:**
- Consumes: `FakeServer`, `FakeBackend`, `RemoteBankingRepository` (Task 3), `HomeModel`, `HomeView` (Task 5), `TransferModel`, `TransferFlowView` (Task 6)
- Produces:

```swift
enum AppEnvironment {
    static let failTransferArgument = "--fail-transfer"
    /// FakeServer(failTransfers: arguments.contains(failTransferArgument))
    /// → FakeBackend.makeSession(server:) → RemoteBankingRepository(session:)
    static func makeRepository(arguments: [String]) -> any BankingRepository
}
struct RootView: View {
    init(repository: any BankingRepository)
}
```

- `PayLabApp`: `AppEnvironment.makeRepository(arguments: ProcessInfo.processInfo.arguments)` 결과를 `RootView`에 넘긴다.
- `RootView`: `@State` `HomeModel`, `@State var transferAccount: Account?`.
  - `NavigationStack { HomeView(model:, onTransfer: { transferAccount = $0 }) }`
  - `.sheet(item: $transferAccount, onDismiss: { Task { await homeModel.load() } })` 안에 `TransferFlowView(model: TransferModel(fromAccount:, repository:), onFinish: { transferAccount = nil })`

- [ ] **Step 1: 위 파일 구현**
- [ ] **Step 2: Run: 생성 → 빌드 → 테스트** — Expected: 테스트 6개 통과
- [ ] **Step 3: 정상 경로 확인 (완료 기준 4)**

**실행** 후 시뮬레이터 제어 도구로 조작하고 단계마다 **스크린샷**:
- 홈에 계좌 3개. `PayLab 통장 1,250,000원` 표시
- PayLab 통장 `송금` → `김하늘` → `10000` → `다음` → `보내기` → `보냈어요`, `남은 잔액 1,240,000원`
- `확인` → 홈에 `PayLab 통장 1,240,000원`

- [ ] **Step 4: Review Focus 1~3, 5 확인**

같은 실행에서:
- 금액 칸에 `1,000원` 입력 → `다음` 활성 (1000으로 인식)
- `99999999999999999999` 입력 → 크래시 없음, `다음` 비활성
- 비상금 통장(`50,000원`): `0` 비활성, `50001` 비활성, `50000` 활성 → 보내기 → `남은 잔액 0원`
- 송금 시트를 열고 받는 사람까지 고른 뒤 쓸어내려 닫기 → 다시 열면 `누구에게 보낼까요?`부터 시작

- [ ] **Step 5: 실패 주입 확인 (완료 기준 5, Review Focus 4)**

**실패 주입 실행** → PayLab 통장에서 `10000` 송금 → `송금 실패` 표시 → `확인` → 홈 잔액 `1,250,000원` 그대로

- [ ] **Step 6: Commit**

```bash
git add Modules/App
git commit -m "feat: App에서 홈·송금 조립, 실패 주입 실행 인자"
```

---

### Task 8: 최종 검증

**Files:** 없음 (문제 발견 시에만 해당 파일 수정)

- [ ] **Step 1: 저장소 상태 (완료 기준 6)**

Run: `git status --porcelain && git ls-files | grep -E 'xcodeproj|xcworkspace|Derived|\.build'`
Expected: 출력 없음

- [ ] **Step 2: 깨끗한 복제본에서 재현 (worktree 호환 확인)**

Run: `git clone . "$TMPDIR/paylab-clone" && cd "$TMPDIR/paylab-clone"` 후 **생성** → **테스트**
Expected: `** TEST SUCCEEDED **`, 테스트 6개 통과

- [ ] **Step 3: CLAUDE.md만으로 동작하는지 (완료 기준 7)**

새 서브에이전트에 지시: "`$TMPDIR/paylab-clone/CLAUDE.md`만 읽고, 거기 적힌 명령으로 프로젝트를 생성하고 테스트를 실행한 뒤 결과를 보고하라."
Expected: 추가 질문 없이 `** TEST SUCCEEDED **` 보고

- [ ] **Step 4: 복제본 삭제** — `rm -rf "$TMPDIR/paylab-clone"`
