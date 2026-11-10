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
