import HerdrKit

enum PreviewData {
    static let hosts = [
        Host(
            displayName: "Desktop",
            hostname: "desktop.local",
            username: "developer"
        ),
    ]

    static let snapshot = HerdrSnapshot(
        sessions: [
            HerdrSession(
                id: "default",
                name: "Default",
                isDefault: true,
                workspaces: [
                    Workspace(
                        id: "workspace-qing",
                        name: "qing",
                        tabs: [
                            Tab(
                                id: "tab-coding",
                                name: "coding",
                                panes: [
                                    Pane(
                                        id: "pane-agent",
                                        title: "Agent",
                                        agent: Agent(name: "Pi", state: .working)
                                    ),
                                    Pane(
                                        id: "pane-reviewer",
                                        title: "Reviewer",
                                        agent: Agent(name: "reviewer", state: .waitingForInput)
                                    ),
                                ]
                            ),
                        ]
                    ),
                ]
            ),
        ]
    )
}
