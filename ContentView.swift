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
