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
