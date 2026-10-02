// swift-tools-version: 6.0
import PackageDescription

// 빌드: scripts/build.sh (swift build + .app 번들 조립). 선택 이유는 decisions/2026-10-02-v0.1.md 참고.
let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchIsland", targets: ["NotchIsland"]),
    ],
    targets: [
        // UI 를 모르는 코어: 수집기 · 이벤트 판정 · 상태 머신 · 설정. 스토어 대비로 센서 모듈은 프로토콜만.
        .target(name: "NotchIslandCore", path: "Sources/NotchIslandCore"),
        // 표시 + 동작 서비스(AppKit/SwiftUI).
        .executableTarget(
            name: "NotchIsland",
            dependencies: ["NotchIslandCore"],
            path: "Sources/NotchIsland"
        ),
        .testTarget(
            name: "NotchIslandCoreTests",
            dependencies: ["NotchIslandCore"],
            path: "Tests/NotchIslandCoreTests"
        ),
        // 앱 쪽(모델 · 그리기) 성능 회귀 테스트. 실행 타깃을 @testable 로 가져온다.
        .testTarget(
            name: "NotchIslandAppTests",
            dependencies: ["NotchIsland", "NotchIslandCore"],
            path: "Tests/NotchIslandAppTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
