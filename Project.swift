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
let modules: [(name: String, dependencies: [String])] = [
    (name: "Domain", dependencies: []),
    (name: "DataKit", dependencies: ["Domain"]),
    (name: "DesignSystem", dependencies: []),
]

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
