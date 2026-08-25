//
//  openvoicerApp.swift
//  openvoicer
//
//  Created by Maksym Dziura on 25.08.2026.
//

import SwiftUI

@main
struct DubLabApp: App {
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
        }
    }
}
