# 블라인드 디버깅 연습 기록

설계: `docs/superpowers/specs/2026-11-10-debugging-design.md` §6.3.
진행: 출제 에이전트 A가 버그를 몰래 심는다 → 해결 에이전트 B가 1단계(로그·도구만, 코드 안 봄)로 용의 위치를 고정한다 → 2단계(코드 열람)로 확정한다 → 메인 세션이 정답과 대조한다.
성공 기준: 1단계에서 정답 함수(또는 뷰)까지 좁힘, 또는 정답 계층까지 좁히고 2단계에서 맞힘.

> 해결 에이전트는 이 파일을 읽지 않는다 (지난 회차 정답이 있음).

## 1회차 — 디코딩 불일치 (성공)

**버그 신고 (A)**
- 제목: 송금 실패 화면이 뜨는데 잔액은 빠져 있음.
- 재현: PayLab 통장 → 송금 → 김하늘 → 10000 → 다음 → 보내기 → 빨간 "송금 실패" → 확인 → 홈 잔액 1,240,000원.
- 기대: 실패면 잔액 그대로, 성공이면 "보냈어요".

**정답 (A)**
- `FakeServer.transfer(body:)`가 영수증을 `{"receipt": {...}}`로 감싸 보낸다 (`Modules/DataKit/Sources/FakeServer.swift:56-58`).
- 앱은 최상위에서 `TransferReceipt`를 디코딩한다 → `keyNotFound(transferID)` → `TransferModel.submit()`이 `.failure`.
- 서버는 응답 전에 이미 잔액을 뺐다.

**B 1단계 (코드 안 봄)**
- 용의 위치: 송금 확인 "보내기"(`submit`) / 저장소 디코딩과 가짜 서버 `POST /transfers`의 경계. 서버가 영수증을 `receipt`로 감싸고 앱은 `<root>`에서 디코딩.
- 결정적 로그:
  ```text
  [network] response 200 POST /transfers 322ms 106B
  [network] body POST /transfers {"receipt":{"balanceAfter":1240000,"transferID":"tr-…","amount":10000}}
  [network] decode failed TransferReceipt POST /transfers: keyNotFound(transferID) at <root>: …
  [transfer] submit failed: DecodingError.keyNotFound: …
  ```
- 확신도: 동작 원리 높음. 고칠 쪽(서버/앱)은 중간. 앱 모델 정의를 1단계에서 볼 수 없었기 때문.

**B 2단계 (코드 확인)**
- `FakeServer.swift:58` `return ok(["receipt": receipt])`로 확정. `Models.swift:43-46`의 `TransferReceipt` 정의가 맞고 서버가 틀렸다고 판단.
- 정답과 일치.

**채점:** 성공. 1단계에서 엔드포인트·계층·원인 메커니즘까지 좁혔다.

**드러난 빈틈과 보강**
- 블라인드 누수: 서브에이전트가 자동으로 받는 git status에 수정 파일명(`FakeServer.swift`)이 보였다. B는 근거에서 제외했다고 보고했다. → 2회차부터 출제 후 `git update-index --assume-unchanged`로 숨긴다.
- `CLAUDE.md`의 `decode failed` 형식 예시가 `typeMismatch` 한 가지뿐이었다. → 일반형 `<종류>(<타입·키>) at <필드 경로>`와 `keyNotFound` 예시를 추가했다.
- `log stream` 첫 줄의 `getpwuid_r …` 잡음. → `CLAUDE.md`에 한 줄 적었다.
- 보강하지 않은 것:
  - `FakeServer`의 처리 로그(잔액 차감 시점). 서버 내부는 설계상 로그 대상이 아니다. 다음 `GET /accounts` 원문으로 추론할 수 있었다.
  - `submit`이 디코딩 실패와 서버 거절을 같은 "실패"로 보여 주는 문제. 실패 처리는 트랜잭션 세션 몫이다.

## 2회차 — 무반응·렌더링 실패 (성공)

**버그 신고 (A)**
- 제목: 받는 사람 카드를 눌러도 다음 화면으로 넘어가지 않음.
- 재현: 송금 → "누구에게 보낼까요?" → 카드 오른쪽 빈 곳·가운데를 누름 → 반응 없음. 여기저기 누르다 보면 가끔 넘어감.
- 화면 모양은 이전과 같음.

**정답 (A)**
- `RecipientListView.swift:19-24`: 카드 꾸밈 수정자(`.frame`, `.padding`, `.background`, `.clipShape`)를 Button label 안에서 `.buttonStyle(.plain)` 뒤로 옮겼다. `.plain` 버튼은 label이 그린 영역(두 `Text`)만 탭을 받는다.

**B 1단계 (코드 안 봄)**
- 용의 위치: 받는 사람 목록 화면 / 뷰 계층 / 받는 사람 카드 행의 Button 탭 영역. 모델·네트워크는 정상.
- 방법: 탭 하나마다 `log stream` 파일에서 `select` 줄을 확인해 반응 영역을 그렸다. 글자 위와 그 주변 약 10pt만 `select recipient=…`가 찍히고, 빈 곳은 로그가 없었다.
- 후보: "카드 배경이 버튼 label 밖에 붙음" / "`.contentShape` 없음" / "`onTapGesture`가 안쪽에 붙음".
- 확신도: 계층 높음, 정확한 코드 원인 중간.

**B 2단계 (코드 확인)**
- `RecipientListView.swift` 13-19행 label에는 글자만 있고, 21-23행 수정자가 label 밖에 있음을 확정했다. 홈의 `AccountRow.swift`가 같은 수정자를 label 안에 둔 대조군이라는 점도 찾았다.
- 정답과 일치.

**채점:** 성공. 1단계에서 뷰·화면·탭 영역까지 좁혔고, 후보 1번이 정답이다.

**드러난 빈틈과 보강**
- 무반응 표에 "같은 버튼이 위치에 따라 반응이 다름(탭 영역 문제)" 경우가 없었다. → `CLAUDE.md` 표에 한 줄 추가했다. 탭마다 로그를 확인해 반응 영역을 그리는 방법도 함께 적었다.
- 뷰 계층·히트 영역을 덤프하는 도구는 없다. 지금은 탭과 로그를 하나씩 맞춰 보는 수작업이 대안이다.
- 연습 절차 문제: `CLAUDE.md` 준비 명령의 `git branch --show-current`가 1단계의 git 금지 규칙과 부딪혔다. → 3회차부터 해결 에이전트 지시에 "`git branch --show-current`만 허용"을 넣는다.
- 블라인드: `assume-unchanged`로 숨긴 뒤에는 B가 git status 누수를 보고하지 않았다.

## 3회차 — 멈춤 (성공)

**버그 신고 (A)**
- 제목: 금액 입력 화면에서 "다음"을 누르면 앱이 굳고 풀리지 않음.
- 재현: PayLab 통장 → 송금 → 김하늘 → 10000 → 다음 → 버튼이 눌린 채 굳음. 키패드·뒤로 가기 무반응. 10초 넘게 그대로.

**정답 (A)**
- 메인 스레드 교착. `TransferModel.proceedToConfirm()`(`@MainActor`)이 새 `latestBalance()`를 부른다. 이 함수는 `Task { fetchAccounts(); semaphore.signal() }` 뒤 `semaphore.wait()`로 기다린다 (`TransferModel.swift:56`, `:64-76`).
- `Task`가 MainActor 격리를 물려받는다. 그래서 막힌 메인 스레드가 비기를 기다리며 영원히 시작하지 못한다.

**B 1단계 (코드 안 봄)**
- 용의 위치: 금액 입력 "다음" / 모델 / `TransferModel.proceedToConfirm()` → `latestBalance()`의 `DispatchSemaphore.wait`.
- 결정적 근거:
  ```text
  2613 closure #1 in closure #1 in AmountInputView.body.getter  (in PayLab.debug.dylib) + 48
  2613 TransferModel.proceedToConfirm()  (in PayLab.debug.dylib) + 204
  2613 TransferModel.latestBalance()  (in PayLab.debug.dylib) + 400
  2613 _dispatch_semaphore_wait_slow  (in libdispatch.dylib) + 128
  2613 semaphore_wait_trap  (in libsystem_kernel.dylib) + 8
  ```
  - 두 번의 `sample`(30초 간격)이 같았다. CPU 0%.
  - 로그는 `select recipient=rcp-1`에서 끊겼다. `confirm …`도, `request GET /accounts`도 없었다. 그래서 잔액 조회 작업이 시작조차 못 했다고 판단했다.
- 추정 원리: 세마포어를 풀 작업이 메인 스레드(MainActor)를 기다리는 교착. 확신도 중간.

**B 2단계:** 생략. 1단계가 정답 함수와 원리까지 맞혔다.

**채점:** 성공. 1단계에서 정답 함수까지 좁혔다.

**드러난 빈틈과 보강**
- 멈춤 절차가 "앱 프레임에 머문 함수"까지만 말했다. 그 아래가 대기 함수인 경우(교착)를 해석하는 안내가 없었다. → `CLAUDE.md`에 `grep -A4`로 앱 프레임 아래를 보고, 계산이면 무거운 작업, 대기+CPU 0%면 교착이라는 구분을 추가했다. CPU 확인 명령(`ps -o %cpu`)도 넣었다.
- 보강하지 않은 것: `latestBalance` 같은 새 코드에는 로그가 없다. 심은 버그 코드라 해당 없다.

## 4회차 — 메모리 누수 (성공)

**버그 신고 (A)**
- 제목: 송금 창을 열었다 닫을 때마다 앱 메모리가 조금씩 쌓이고, 닫은 뒤에도 줄지 않는다.
- 재현: 송금 → 닫기를 여러 번 반복한다(끝까지 송금 → 확인도 같다). 화면 동작은 정상이다.

**정답 (A)**
- 순환 참조. `TransferFlowView.swift:25` `.onAppear { model.onFinish = { dismiss() } }`. `dismiss`는 `self.dismiss`라서 클로저가 뷰 구조체 전체를 캡처하고, 그 안의 `@State model` 저장소를 통해 `TransferModel`을 잡는다.
- `TransferModel.swift:18` `public var onFinish`가 그 클로저를 강하게 보관한다. "닫기 로직을 모델로 옮기는 리팩터"처럼 위장했다(파일 5개 수정).

**B 1단계 (코드 안 봄)**
- 용의 위치: 송금 시트 / 모델과 뷰 사이 클로저 연결 / `TransferModel._onFinish` ↔ 클로저 컨텍스트 순환, `StoredLocation<TransferModel>` 경유.
- 결정적 근거:
  - `heap`의 `TransferModel` 개수가 시트를 연 횟수와 1:1로 늘었다(0 → 1 → 3 → 4).
  - `leaks` 순환 트리:
    ```text
    ROOT CYCLE: <TransferModel 0x104574b40> [320]
       __strong _onFinish.context --> ROOT CYCLE: <Closure context (unknown layout) 0x1045d2300> [64]
          CYCLE BACK TO <TransferModel 0x104574b40> [320]
          ROOT CYCLE: <SwiftUI.StoredLocation<TransferFeature.TransferModel> 0x1044346c0> [96]
             __strong data.value._rawLayout.currentValue --> CYCLE BACK TO <TransferModel 0x104574b40> [320]
    ```
  - 로그는 모두 정상이었다. 로그만으로는 이 버그가 보이지 않는다.
- 추정: 시트 안에서 `@State model`과 `@Environment(\.dismiss)`를 가진 뷰가 `model.onFinish = { … }`로 `self`를 캡처한다. 클로저가 만들어지는 정확한 뷰는 확신도 중간.

**B 2단계 (코드 확인)**
- `TransferFlowView.swift:25`로 확정했다. 정답과 일치한다.
- "`dismiss()` 한 단어가 구조체 전체를 끌고 들어간다", "순환은 닫을 때가 아니라 열 때 생긴다"는 점을 코드에서 확인했다.

**채점:** 성공. 1단계에서 타입·속성·순환 경로까지 좁혔다. 클로저를 만드는 뷰는 추정(중간)이었고, 2단계에서 맞혔다.

**드러난 빈틈과 보강**
- 클로저가 어디서 만들어졌는지 1단계에서 확정할 도구가 없었다. → 메인 세션이 같은 버그로 `malloc_history $PID <Closure context 주소>`를 확인했다. 할당 스택에 `closure #2 in TransferFlowView.body.getter`가 나왔다. 이 명령을 `CLAUDE.md`에 추가했다.
- `leaks` 출력 읽는 법이 없었다(`_속성` = `@Observable` 속성, `StoredLocation` = `@State`, `PresentationMode` = 시트 dismiss). → `CLAUDE.md`에 추가했다.
- `leaks`가 마지막 인스턴스 하나를 누수로 세지 않았다(보수적 스캔). → `heap` 개수를 기준으로 삼는다고 적었다.
- `DYLD_SHARED_REGION…`, `not debuggable` 경고. → 잡음으로 적었다.
- 설계 §8의 미확인 가정 "`leaks`가 누수 객체의 타입 이름을 보여 준다"가 확인됐다. `MallocStackLogging`을 켜고 실행하면 타입 이름, 순환 경로, 할당 스택이 모두 나온다.
- 연습 절차 문제: 출제 에이전트가 공용 scratchpad에 버그 백업과 `leaks` 원본을 남겼다. 1·2회차의 정답 메모도 같은 곳에 있었다. → 해결 에이전트 투입 전에 비공개 폴더로 옮겼다. 해결 에이전트는 전용 하위 폴더만 쓰게 했다.
