import Foundation

struct NewProjectDraft: Identifiable {
    let id = UUID()
    let sourceURL: URL
    var metadata: VideoMetadata
    var embeddedSubtitleTracks: [EmbeddedSubtitleTrack]
    var selectedAudioTrackID: String
    var scopeMode: ProjectMediaScope.Mode = .fullMovie
    var clipStartTime: TimeInterval = 0
    var clipEndTime: TimeInterval
    var audioPreparationPreference: AudioPreparationPreference = .automatic
    var dialogueCleaningPreset: DialogueCleaningPreset = .balanced
    var prepareBackgroundAfterCreation = true
    var selectedEmbeddedSubtitleStreamIndex: Int?

    init(
        sourceURL: URL,
        metadata: VideoMetadata,
        embeddedSubtitleTracks: [EmbeddedSubtitleTrack]
    ) {
        self.sourceURL = sourceURL
        self.metadata = metadata
        self.embeddedSubtitleTracks = embeddedSubtitleTracks
        selectedAudioTrackID = metadata.audioTracks.first?.id ?? ""
        clipEndTime = min(metadata.duration, 300)
        selectedEmbeddedSubtitleStreamIndex = embeddedSubtitleTracks.first(where: \.isTextBased)?.streamIndex
    }

    var selectedAudioTrack: AudioTrackMetadata? {
        metadata.audioTracks.first { $0.id == selectedAudioTrackID } ?? metadata.audioTracks.first
    }

    var musicAndEffectsCandidate: AudioTrackMetadata? {
        guard let selectedAudioTrack else { return nil }
        return metadata.audioTracks.first {
            $0.id != selectedAudioTrack.id && $0.isLikelyMusicAndEffects
        }
    }

    var recommendedStrategy: AudioPreparationStrategy {
        if musicAndEffectsCandidate != nil { return .embeddedMusicAndEffects }
        if (selectedAudioTrack?.channelCount ?? 2) >= 6 { return .surroundAssisted }
        return .cinematicSeparation
    }

    var effectiveStrategy: AudioPreparationStrategy? {
        switch audioPreparationPreference {
        case .automatic: recommendedStrategy
        case .embeddedMusicAndEffects: .embeddedMusicAndEffects
        case .surroundAssisted: .surroundAssisted
        case .cinematicSeparation: .cinematicSeparation
        case .duckingOnly: nil
        }
    }

    var mediaScope: ProjectMediaScope {
        switch scopeMode {
        case .fullMovie:
            .fullMovie
        case .clip:
            .clip(start: normalizedClipStart, end: normalizedClipEnd)
        }
    }

    var normalizedClipStart: TimeInterval {
        min(max(clipStartTime, 0), max(metadata.duration - 1, 0))
    }

    var normalizedClipEnd: TimeInterval {
        min(max(clipEndTime, normalizedClipStart + 1), metadata.duration)
    }

    var selectedDuration: TimeInterval {
        scopeMode == .fullMovie ? metadata.duration : max(0, normalizedClipEnd - normalizedClipStart)
    }

    var canCreate: Bool {
        selectedAudioTrack != nil
            && (scopeMode == .fullMovie || normalizedClipEnd > normalizedClipStart)
    }

    func supports(_ preference: AudioPreparationPreference) -> Bool {
        switch preference {
        case .automatic, .cinematicSeparation, .duckingOnly:
            true
        case .embeddedMusicAndEffects:
            musicAndEffectsCandidate != nil
        case .surroundAssisted:
            (selectedAudioTrack?.channelCount ?? 0) >= 6
        }
    }
}
