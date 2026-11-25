import Testing
@testable import OpenIslandCore

/// Verifies the per-process hook skip environment contract.
/// 验证单次子进程 hook 跳过环境变量协议。
struct HookSkipConfigurationTests {
    @Test
    func t3ProviderMarkersAreExactAndSourceSpecific() {
        let codex = ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "T3 Code"]
        let claude = ["CLAUDE_CODE_ENTRYPOINT": "t3-code"]
        #expect(HookSkipConfiguration.shouldSkipHooks(environment: codex, source: "codex"))
        #expect(HookSkipConfiguration.shouldSkipHooks(environment: claude, source: "claude"))
        #expect(!HookSkipConfiguration.shouldSkipHooks(environment: codex, source: "claude"))
        #expect(!HookSkipConfiguration.shouldSkipHooks(environment: claude, source: "codex"))
        #expect(!HookSkipConfiguration.shouldSkipHooks(environment: codex))
        for marker in ["T3 Code CLI", "t3 code", "Codex Desktop", "codex-tui"] {
            #expect(!HookSkipConfiguration.shouldSkipHooks(environment: ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": marker], source: "codex"))
        }
        #expect(!HookSkipConfiguration.shouldSkipHooks(environment: ["CLAUDE_CODE_ENTRYPOINT": "t3-code-wrapper"], source: "claude"))
        #expect(!HookSkipConfiguration.shouldSkipHooks(environment: claude, source: "qoder"))
    }

    /// Accepts common truthy spellings for the preferred Open Island key.
    /// 推荐的新环境变量接受常见真值写法。
    @Test
    func openIslandSkipHooksAcceptsTruthyValues() {
        for value in ["1", "true", "TRUE", "yes", "on", " 1 "] {
            #expect(HookSkipConfiguration.shouldSkipHooks(environment: [
                HookSkipConfiguration.openIslandSkipKey: value,
            ]))
        }
    }

    /// Keeps compatibility with existing Vibe Island-based wrappers.
    /// 保留对已有 Vibe Island wrapper 的兼容。
    @Test
    func legacyVibeIslandSkipAliasIsSupported() {
        #expect(HookSkipConfiguration.shouldSkipHooks(environment: [
            HookSkipConfiguration.legacyVibeIslandSkipKey: "1",
        ]))
    }

    /// Rejects unset or non-truthy values so hooks remain enabled by default.
    /// 未设置或非真值时保持默认启用 hook。
    @Test
    func skipHooksRejectsFalsyOrMissingValues() {
        for value in ["", "0", "false", "no", "off", "random"] {
            #expect(!HookSkipConfiguration.shouldSkipHooks(environment: [
                HookSkipConfiguration.openIslandSkipKey: value,
            ]))
        }

        #expect(!HookSkipConfiguration.shouldSkipHooks(environment: [:]))
    }
}
