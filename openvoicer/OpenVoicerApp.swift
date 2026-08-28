//
//  openvoicerApp.swift
//  openvoicer
//
//  Created by Maksym Dziura on 25.08.2026.
//

import SwiftUI

@main
struct OpenVoicerApp: App {
    @State private var projectController = ProjectController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: projectController)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") {
                    projectController.showNewProjectPanel()
                }
                .keyboardShortcut("n")

                Button("Open Project…") {
                    projectController.showOpenProjectPanel()
                }
                .keyboardShortcut("o")

                Divider()

                Button("Import Video…") {
                    projectController.showVideoImportPanel()
                }
                .keyboardShortcut("i")
                .disabled(projectController.project == nil)
            }

            CommandGroup(after: .saveItem) {
                Button("Save Project") {
                    projectController.save()
                }
                .keyboardShortcut("s")
                .disabled(projectController.project == nil)
            }

            CommandMenu("Dubbing") {
                Button("Play Original Segment") {
                    projectController.playSelectedSegment()
                }
                .keyboardShortcut("p", modifiers: [])
                .disabled(projectController.selectedSegment == nil || projectController.recording.isActive)

                Divider()

                Button(projectController.recording.isActive ? "Stop Recording" : "Record") {
                    projectController.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [])
                .disabled(projectController.selectedSegment == nil || projectController.recording.state == .finishing)

                Button("Record Another Take") {
                    projectController.toggleRecording()
                }
                .keyboardShortcut("t", modifiers: [])
                .disabled(
                    projectController.recording.isActive ||
                    projectController.selectedSegment?.takes.isEmpty != false
                )

                Button("Accept Previewed Result and Next") {
                    projectController.acceptSelectedVersionAndAdvance()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!projectController.canAcceptSelectedVersion)

                Divider()

                Button("Previous Segment") {
                    projectController.selectPreviousSegment()
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(projectController.selectedSegment == nil || projectController.recording.isActive)

                Button("Next Segment") {
                    projectController.selectNextSegment()
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(projectController.selectedSegment == nil || projectController.recording.isActive)
            }
        }
    }
}
