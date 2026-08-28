import SwiftUI

enum WorkspaceInspectorSection: String, CaseIterable, Identifiable {
    case dubbing
    case microphone
    case dialogue
    case audio
    case project
    case export

    var id: Self { self }

    var title: String {
        switch self {
        case .dubbing: "Dubbing"
        case .microphone: "Microphone"
        case .dialogue: "Dialogue"
        case .audio: "Audio"
        case .project: "Project"
        case .export: "Export"
        }
    }

    var symbol: String {
        switch self {
        case .dubbing: "mic.badge.plus"
        case .microphone: "mic"
        case .dialogue: "captions.bubble"
        case .audio: "waveform.badge.minus"
        case .project: "info.circle"
        case .export: "square.and.arrow.up"
        }
    }

    var selectedSymbol: String {
        switch self {
        case .dubbing: "mic.badge.plus"
        case .microphone: "mic.fill"
        case .dialogue: "captions.bubble.fill"
        case .audio: "waveform.badge.minus"
        case .project: "info.circle.fill"
        case .export: "square.and.arrow.up.fill"
        }
    }
}

struct ProjectView: View {
    @Bindable var controller: ProjectController
    @State private var isShowingInspector = true
    @State private var inspectorSection: WorkspaceInspectorSection = .dubbing

    var body: some View {
        HSplitView {
            SegmentSidebarView(controller: controller)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 370)

            VideoWorkspaceView(controller: controller)
                .frame(minWidth: 620)
        }
        .navigationTitle(controller.project?.name ?? "DubLab")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(WorkspaceInspectorSection.allCases) { section in
                    inspectorButton(section)
                }
            }
        }
        .inspector(isPresented: $isShowingInspector) {
            WorkspaceInspectorView(section: inspectorSection, controller: controller)
                .inspectorColumnWidth(min: 285, ideal: 320, max: 390)
        }
    }

    private func inspectorButton(_ section: WorkspaceInspectorSection) -> some View {
        let isSelected = isShowingInspector && inspectorSection == section

        return Button {
            if isSelected {
                isShowingInspector = false
            } else {
                inspectorSection = section
                isShowingInspector = true
            }
        } label: {
            Label(section.title, systemImage: isSelected ? section.selectedSymbol : section.symbol)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .help(isSelected ? "Hide \(section.title) Inspector" : "Show \(section.title) Inspector")
    }
}
