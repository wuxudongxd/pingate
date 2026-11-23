import Foundation

public struct TargetTemplate: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let iconSystemName: String
    private let factory: @Sendable (UUID) -> [ManagedTarget]

    public init(
        id: String,
        name: String,
        description: String,
        iconSystemName: String,
        factory: @escaping @Sendable (UUID) -> [ManagedTarget]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.iconSystemName = iconSystemName
        self.factory = factory
    }

    public func makeTargets(outletID: UUID) -> [ManagedTarget] {
        factory(outletID)
    }

    public static func == (lhs: TargetTemplate, rhs: TargetTemplate) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.description == rhs.description &&
        lhs.iconSystemName == rhs.iconSystemName
    }
}

public enum PinGateTemplates {
    public static let antigravitySuite = TargetTemplate(
        id: "antigravity-suite",
        name: "Antigravity + T3 Code + agy",
        description: "将 Antigravity.app（含 language_server）、T3 Code 的 Antigravity 提供商与 agy CLI 固定到所选出口。",
        iconSystemName: "sparkles"
    ) { outletID in
        [
            ManagedTarget(
                name: "Antigravity",
                kind: .guiApp,
                outletID: outletID,
                enabled: true,
                bundleID: "com.google.antigravity",
                appPath: "/Applications/Antigravity.app",
                processMatchNames: ["Antigravity", "language_server", "antigravity"],
                chromiumProxyFlags: true,
                extraEnv: ["NODE_USE_ENV_PROXY": "1"]
            ),
            ManagedTarget(
                name: "T3 Code",
                kind: .t3Integration,
                outletID: outletID,
                enabled: true,
                processMatchNames: ["T3 Code", "t3code"],
                extraEnv: ["NODE_USE_ENV_PROXY": "1"],
                t3SettingsPath: "~/.t3/userdata/settings.json",
                t3ProviderKey: "antigravity"
            ),
            ManagedTarget(
                name: "agy",
                kind: .cliTool,
                outletID: outletID,
                enabled: true,
                processMatchNames: ["agy"],
                extraEnv: ["NODE_USE_ENV_PROXY": "1"],
                cliCommandName: "agy",
                cliTargetBinaryPath: "/opt/homebrew/bin/agy"
            )
        ]
    }

    public static let cursor = TargetTemplate(
        id: "cursor",
        name: "Cursor",
        description: "将 Cursor.app 及其 Node/Electron 子进程固定到所选出口。",
        iconSystemName: "cursorarrow.rays"
    ) { outletID in
        [
            ManagedTarget(
                name: "Cursor",
                kind: .guiApp,
                outletID: outletID,
                enabled: true,
                bundleID: "com.todesktop.230313mzl4w4u92",
                appPath: "/Applications/Cursor.app",
                processMatchNames: ["Cursor", "cursor"],
                chromiumProxyFlags: true,
                extraEnv: ["NODE_USE_ENV_PROXY": "1"]
            )
        ]
    }

    public static let claudeCode = TargetTemplate(
        id: "claude-code",
        name: "Claude Code",
        description: "通过 ~/.local/bin/claude 封装脚本固定 claude CLI，并自动注入 NODE_USE_ENV_PROXY=1。",
        iconSystemName: "terminal"
    ) { outletID in
        [
            ManagedTarget(
                name: "Claude Code",
                kind: .cliTool,
                outletID: outletID,
                enabled: true,
                processMatchNames: ["claude"],
                extraEnv: ["NODE_USE_ENV_PROXY": "1"],
                cliCommandName: "claude",
                cliTargetBinaryPath: "/opt/homebrew/bin/claude"
            )
        ]
    }

    public static let custom = TargetTemplate(
        id: "custom",
        name: "自定义应用 / CLI",
        description: "创建一个可自定义的桌面应用目标，指向任意 macOS 应用。",
        iconSystemName: "plus.app"
    ) { outletID in
        [
            ManagedTarget(
                name: "自定义应用",
                kind: .guiApp,
                outletID: outletID,
                enabled: true,
                appPath: "/Applications/",
                processMatchNames: [],
                chromiumProxyFlags: true,
                extraEnv: ["NODE_USE_ENV_PROXY": "1"]
            )
        ]
    }

    public static let all: [TargetTemplate] = [
        antigravitySuite,
        cursor,
        claudeCode,
        custom
    ]
}
