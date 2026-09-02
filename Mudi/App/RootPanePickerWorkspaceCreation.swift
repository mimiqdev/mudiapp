import Foundation
import HerdrKit

/// Coordinates the V1 global Picker Create action. Creation is intentionally
/// a single remote workspace command followed by the normal discovery and
/// pane takeover path; it never creates a Git worktree or focuses Herdr.
extension RootViewModel {
    func createWorkspaceFromPicker() {
        guard !isCreatingWorkspace,
              !isSceneInactive,
              isPanePickerPresented,
              let workflow,
              let pickerCoordinator = self.panePickerCoordinator
        else { return }

        isCreatingWorkspace = true
        let generation = connectionGeneration
        let workspaceCreationID = UUID()
        self.workspaceCreationID = workspaceCreationID
        let task = Task { [weak self, workflow, pickerCoordinator] in
            defer {
                if let self,
                   self.workspaceCreationID == workspaceCreationID {
                    self.workspaceCreationTask = nil
                    self.isCreatingWorkspace = false
                    self.terminalSessionCloseSuppressed = false
                }
            }

            do {
                guard let creator = workflow as? any HerdrWorkspaceCreating else {
                    throw HerdrWorkflowError.workspaceCreationUnavailable
                }
                let creation = try await creator.createWorkspace()
                guard let self,
                      self.canContinueWorkspaceCreation(
                          generation: generation,
                          workflow: workflow,
                          pickerMustBePresented: true
                      )
                else { return }

                let refreshedState = await pickerCoordinator.refreshPicker()
                guard self.canContinueWorkspaceCreation(
                    generation: generation,
                    workflow: workflow,
                    pickerMustBePresented: true
                ) else { return }
                guard case let .panePicker(picker) = refreshedState else {
                    self.presentWorkspaceCreationError(
                        PanePickerWorkspaceCreationError.refreshUnavailable
                    )
                    return
                }
                await self.applyPanePickerState(
                    refreshedState,
                    workflow: workflow
                )
                guard picker.message == nil,
                      self.canContinueWorkspaceCreation(
                          generation: generation,
                          workflow: workflow,
                          pickerMustBePresented: true
                      )
                else { return }
                guard panePickerLocation(
                    in: picker.snapshot,
                    paneID: creation.rootPaneID
                ) != nil else {
                    self.presentWorkspaceCreationError(
                        PanePickerWorkspaceCreationError.rootPaneUnavailable
                    )
                    return
                }

                // The ordinary Picker selection path uses this same
                // suppression while release/takeover can close the old
                // control stream.
                self.terminalSessionCloseSuppressed = true
                let selectionState = await pickerCoordinator.selectPane(
                    creation.rootPaneID
                )
                guard self.canContinueWorkspaceCreation(
                    generation: generation,
                    workflow: workflow,
                    pickerMustBePresented: false
                ) else { return }
                await self.applyPanePickerState(
                    selectionState,
                    workflow: workflow
                )
            } catch {
                guard let self,
                      self.canContinueWorkspaceCreation(
                          generation: generation,
                          workflow: workflow,
                          pickerMustBePresented: true
                      )
                else { return }
                self.presentWorkspaceCreationError(error)
            }
        }
        workspaceCreationTask = task
    }

    private func canContinueWorkspaceCreation(
        generation: UUID,
        workflow: any HerdrWorkflowCoordinating,
        pickerMustBePresented: Bool
    ) -> Bool {
        connectionGeneration == generation
            && isCurrentWorkflow(workflow)
            && (!pickerMustBePresented || isPanePickerPresented)
            && !isSceneInactive
            && !Task.isCancelled
    }

    private func presentWorkspaceCreationError(_ error: Error) {
        guard var picker = panePicker else { return }
        picker.message = panePickerPresentableMessage(for: error)
        picker.isLoading = false
        self.panePicker = picker
    }
}

enum PanePickerWorkspaceCreationError: Error, LocalizedError, Sendable {
    case refreshUnavailable
    case rootPaneUnavailable

    var errorDescription: String? {
        switch self {
        case .refreshUnavailable:
            "The new Herdr workspace could not be discovered."
        case .rootPaneUnavailable:
            "The new Herdr workspace root pane was not found after refresh."
        }
    }
}
