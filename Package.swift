// swift-tools-version: 6.4
import PackageDescription

/// Upcoming-language features and checks applied to every Swift target,
/// tests included, so the library and its tests compile under one dialect.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
]

let package = Package(
    name: "swift-calendar-automation",
    platforms: [.macOS("27.2")],
    products: [
        .library(name: "CalendarAutomation", targets: ["CalendarAutomation"]),
    ],
    targets: [
        .target(
            name: "CalendarAutomation",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CalendarAutomationTests",
            dependencies: ["CalendarAutomation"],
            swiftSettings: swiftSettings
        ),
    ],
    // Already the default for tools 6.4; stated so the dialect doesn't
    // silently change with a future tools-version bump.
    swiftLanguageModes: [.v6]
)
