import Foundation

/// A single billable unit of token consumption parsed from a local session log.
/// Every provider's reader emits these so the cost pipeline downstream is
/// provider-agnostic.
struct TokenEvent {
    /// The five providers the cost pipeline can attribute spend to. Mirrors
    /// `DisplayProvider`; kept as `TokenEvent`'s own nested type because
    /// downstream code (e.g. `CostBlock`) refers to it as `TokenEvent.Provider`.
    enum Provider {
        case claude
        case codex
        case antigravity
        case grok
        case cursor
    }

    let provider: Provider
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    /// Tokens written to the prompt cache during this turn. Anthropic-only.
    let cacheCreationTokens: Int
    /// Tokens served from the prompt cache during this turn. Both providers
    /// (Codex calls these "cached_input_tokens" — they are billed at a
    /// discount but still draw from the input bucket).
    let cacheReadTokens: Int
    /// Dollar cost the provider reported for this turn, when it ships its own
    /// figure (Grok's `costUsdTicks`). When non-nil this OVERRIDES the
    /// `Pricing`-table computation for this event — the provider's own number
    /// is authoritative. Table-priced providers (Claude, Codex, Cursor) leave
    /// it nil and stay costed from the embedded rate snapshot.
    let selfReportedCostUSD: Double?

    // Explicit memberwise init: a `let` with a default value is dropped from
    // Swift's synthesized initializer, which would make `selfReportedCostUSD`
    // unsettable by Grok's reader. Declaring the init keeps the new field
    // settable while defaulting it to nil so every existing construction site
    // (ClaudeLogReader / CodexLogReader) compiles unchanged.
    init(
        provider: Provider,
        timestamp: Date,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        selfReportedCostUSD: Double? = nil
    ) {
        self.provider = provider
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.selfReportedCostUSD = selfReportedCostUSD
    }

    /// Dollar cost for this event. When a provider ships its own figure
    /// (Grok's `costUsdTicks`, carried in `selfReportedCostUSD`) that number
    /// OVERRIDES the Pricing table — Grok is never priced from a table it has
    /// no entry in. Table-priced providers (Claude, Codex) fall back to the
    /// embedded rate snapshot; providers with no table entry (Cursor, Gemini)
    /// price to 0, surfaced as "—" upstream, never a coined dollar figure.
    /// Mirrors the C# `TokenEvent.Dollars`; consumers must read this rather
    /// than calling `Pricing.cost(for:)` directly, or self-reported cost is lost.
    var dollars: Double {
        selfReportedCostUSD ?? Pricing.cost(for: self)
    }
}
