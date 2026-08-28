//
//  ContentView.swift
//  openvoicer
//
//  Created by Maksym Dziura on 25.08.2026.
//

import SwiftUI

struct ContentView: View {
    @Bindable var controller: ProjectController

    var body: some View {
        Group {
            if controller.project == nil {
                WelcomeView(controller: controller)
            } else {
                ProjectView(controller: controller)
            }
        }
        .overlay {
            if controller.isInspectingNewMovie {
                ZStack {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Inspecting movie and audio tracks…")
                            .font(.headline)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .sheet(item: $controller.newProjectDraft, onDismiss: {
            controller.dismissNewProjectAssistant()
        }) { _ in
            NewProjectAssistantView(controller: controller)
        }
        .alert("DubLab", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {
                controller.errorMessage = nil
            }
        } message: {
            Text(controller.errorMessage ?? "An unknown error occurred.")
        }
        .onOpenURL { url in
            controller.openProjectURL(url)
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )
    }
}

#Preview {
    ContentView(controller: ProjectController())
        .frame(width: 1100, height: 720)
}
