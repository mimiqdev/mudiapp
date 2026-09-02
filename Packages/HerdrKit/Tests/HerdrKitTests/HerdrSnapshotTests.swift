import Foundation
import Testing
@testable import HerdrKit

@Test func worktreeMetadataDecodesAndLegacyWorkspaceDefaultsToNil() throws {
    let payload = #"""
    {
      "id": "linked",
      "name": "phase6-pane-picker-impl",
      "tabs": [],
      "worktree": {
        "checkout_path": "/Users/tony.liu/Developer/personal/mudiapp-phase6-pane-picker-impl",
        "is_linked_worktree": true,
        "repo_key": "/Users/tony.liu/Developer/personal/mudiapp/.git",
        "repo_name": "mudiapp",
        "repo_root": "/Users/tony.liu/Developer/personal/mudiapp"
      }
    }
    """#
    let linkedWorkspace = try JSONDecoder().decode(
        Workspace.self,
        from: Data(payload.utf8)
    )
    let worktree = try #require(linkedWorkspace.worktree)

    #expect(worktree.checkoutPath == "/Users/tony.liu/Developer/personal/mudiapp-phase6-pane-picker-impl")
    #expect(worktree.isLinkedWorktree)
    #expect(worktree.repoKey == "/Users/tony.liu/Developer/personal/mudiapp/.git")
    #expect(worktree.repoName == "mudiapp")
    #expect(worktree.repoRoot == "/Users/tony.liu/Developer/personal/mudiapp")

    let legacyPayload = #"""
    {
      "id": "legacy",
      "name": "legacy",
      "tabs": []
    }
    """#
    let legacyWorkspace = try JSONDecoder().decode(
        Workspace.self,
        from: Data(legacyPayload.utf8)
    )
    #expect(legacyWorkspace.worktree == nil)
}
