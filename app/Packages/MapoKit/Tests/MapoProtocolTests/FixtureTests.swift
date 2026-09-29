import Foundation
import Testing

@testable import MapoProtocol

/// The daemon's canonical JSON (`crates/mapo-protocol/fixtures`) must decode into the hand-written types.
struct FixtureTests {
    private static let fixtures = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../../../../crates/mapo-protocol/fixtures")
        .standardized

    private func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let data = try Data(contentsOf: Self.fixtures.appending(component: "\(name).json"))
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test func fixturesDecode() throws {
        let snapshot = try load("snapshot", as: StateSnapshot.self)
        let event = try load("event-tab-created", as: Event.self)
        let error = try load("error", as: RPCError.self)
        let hello = try load("hello-result", as: HelloResult.self)
        let layout = try load("layout", as: Layout.self)
        let tab = try load("tab-summary", as: TabSummary.self)
        let workspace = try load("workspace-summary", as: WorkspaceSummary.self)
        guard case .tabCreated(let created) = event.payload else {
            Issue.record("event payload is \(event.payload)")
            return
        }
        let summary = [
            "snapshot": "\(snapshot.seq) \(snapshot.workspaces.map(\.name)) \(snapshot.tabs.map(\.name))",
            "focused": snapshot.layouts[workspace.id]?.focusedPane.flatMap { $0.content.tabId } ?? "none",
            "event": "\(event.seq) \(event.type) \(created.name) at=\(event.at?.intValue ?? 0)",
            "error": "\(error.kind?.rawValue ?? "?") \(error.data?.hint ?? "")",
            "hello": "\(hello.instance) \(hello.protocol) \(hello.caller?.kind ?? "?")",
            "layout": layout.focusedPane?.id ?? "none",
            "tab": "\(tab.name) \(tab.state.rawValue) \(tab.kind) \(tab.labeled) \(tab.launch?.cwd ?? "")",
            "workspace": "\(workspace.name) \(workspace.tabCount) \(workspace.activeTabId ?? "")",
        ]
        #expect(
            summary == [
                "snapshot": "6 [\"Obsess\"] [\"be\"]",
                "focused": "0199a3c2-0000-7000-8000-000000000002",
                "event": "5 tab.created be at=1790000000000",
                "error": "not_found mapo tab list",
                "hello": "dev-mapo-native 1 app",
                "layout": "0199a3c3-0000-7000-8000-000000000003",
                "tab": "be idle shell true /usr/bin",
                "workspace": "Obsess 1 0199a3c2-0000-7000-8000-000000000002",
            ])
    }

    @Test func helloParamsEncodeLikeTheDaemon() throws {
        let params = HelloParams(role: "app", client: "Mapo/0.1.0", credential: .app(token: "TOKEN"))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? NSDictionary
        let expected =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: Self.fixtures.appending(component: "hello-params.json"))) as? NSDictionary
        #expect(encoded == expected)
    }
}
