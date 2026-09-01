enum ReminderDeliveryKey {
    static func make(
        providerRawValue: String,
        stateRawValue: Int,
        transcriptPath: String?,
        sessionId: String,
        cwd: String,
        label: String,
        turnKey: String?
    ) -> String {
        let thread = threadKey(
            transcriptPath: transcriptPath,
            sessionId: sessionId,
            cwd: cwd,
            label: label
        )
        let turn = normalizedTurnKey(turnKey)
        return "\(providerRawValue)-\(stateRawValue)-\(thread)-\(turn)"
    }

    static func threadKey(
        transcriptPath: String?,
        sessionId: String,
        cwd: String,
        label: String
    ) -> String {
        if let transcriptPath, !transcriptPath.isEmpty { return transcriptPath }
        if !sessionId.isEmpty { return sessionId }
        if !cwd.isEmpty { return "\(cwd):\(label)" }
        return label
    }

    private static func normalizedTurnKey(_ turnKey: String?) -> String {
        guard let turnKey, !turnKey.isEmpty else { return "latest" }
        return turnKey
    }
}
