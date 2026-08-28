import Foundation
import Testing
@testable import DubLabModels

struct ProjectModelTests {
    @Test func projectRoundTripsSegments() throws {
        var project = DubProject(name: "Example")
        var segment = DubSegment(startTime: 1.25, endTime: 3.5, text: "Dialogue")
        let takeID = UUID()
        segment.acceptedVersion = AcceptedSegmentVersion(takeID: takeID, treatment: .cleanDub)
        project.segments = [segment]

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(DubProject.self, from: data)

        #expect(decoded == project)
        #expect(decoded.segments.first?.duration == 2.25)
        #expect(decoded.segments.first?.acceptedVersion?.takeID == takeID)
        #expect(decoded.segments.first?.acceptedVersion?.treatment == .cleanDub)
    }

    @Test func olderSegmentWithoutAcceptedVersionStillDecodes() throws {
        var project = DubProject(name: "Before Per-Line Mix Decisions")
        project.segments = [DubSegment(startTime: 1, endTime: 2, text: "Legacy")]
        let encoded = try JSONEncoder().encode(project)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var segments = try #require(object["segments"] as? [[String: Any]])
        segments[0].removeValue(forKey: "acceptedVersion")
        object["segments"] = segments

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(DubProject.self, from: legacyData)

        #expect(decoded.segments.first?.acceptedVersion == nil)
    }

    @Test func versionOneProjectMigratesWithEmptyPhaseTwoFields() throws {
        let project = DubProject(name: "Legacy")
        let encoded = try JSONEncoder().encode(project)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 1
        object.removeValue(forKey: "subtitleSource")
        object.removeValue(forKey: "segments")
        object.removeValue(forKey: "speakers")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(DubProject.self, from: legacyData)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.segments.isEmpty)
        #expect(decoded.speakers.isEmpty)
        #expect(decoded.subtitleSource == nil)
    }

    @Test func phaseTwoSettingsReceiveRecordingDefaults() throws {
        let project = DubProject(name: "Phase Two")
        let encoded = try JSONEncoder().encode(project)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 2
        var settings = try #require(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "selectedInputDeviceID")
        settings.removeValue(forKey: "recordingCountdownSeconds")
        settings.removeValue(forKey: "recordingGain")
        object["settings"] = settings
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(DubProject.self, from: legacyData)

        #expect(decoded.settings.selectedInputDeviceID == nil)
        #expect(decoded.settings.recordingCountdownSeconds == 3)
        #expect(decoded.settings.recordingGain == 1)
    }

    @Test func projectRoundTripsSeparatedBackgroundReference() throws {
        var project = DubProject(name: "Separated")
        var segment = DubSegment(startTime: 10, endTime: 12.5, text: "Hello")
        segment.separatedBackground = SourceSeparationAsset(
            fileName: "segment.wav",
            preRollDuration: 2,
            modelID: "bandit-v2-multi",
            sourceAudioTrackID: "audio-1"
        )
        project.segments = [segment]

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(DubProject.self, from: data)

        #expect(decoded.segments.first?.separatedBackground == segment.separatedBackground)
    }

    @Test func olderProjectReceivesDialogueCleaningDefaults() throws {
        let project = DubProject(name: "Before Cleaning Controls")
        let encoded = try JSONEncoder().encode(project)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 4
        var settings = try #require(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "dialogueCleaningPreset")
        settings.removeValue(forKey: "cleanBackgroundVolume")
        settings.removeValue(forKey: "selectedAudioTrackID")
        settings.removeValue(forKey: "playSourceAudioWhileRecording")
        object["settings"] = settings

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(DubProject.self, from: legacyData)

        #expect(decoded.settings.dialogueCleaningPreset == .balanced)
        #expect(decoded.settings.cleanBackgroundVolume == 1)
        #expect(decoded.settings.selectedAudioTrackID == nil)
        #expect(decoded.settings.playSourceAudioWhileRecording == false)
    }

    @Test func selectedAudioTrackPersists() throws {
        var project = DubProject(name: "English Dub")
        project.settings.selectedAudioTrackID = "audio-1"
        project.settings.playSourceAudioWhileRecording = true

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(DubProject.self, from: data)
        #expect(decoded.settings.playSourceAudioWhileRecording)

        #expect(decoded.settings.selectedAudioTrackID == "audio-1")
    }

    @Test func continuousPreparedAudioRoundTripsAndMigrates() throws {
        var project = DubProject(name: "Continuous Stems")
        project.preparedAudioAssets = [
            PreparedAudioAsset(
                sourceAudioTrackID: "audio-0",
                strategy: .surroundAssisted,
                dialogueFileName: "audio-0/dialogue.wav",
                backgroundFileName: "audio-0/background.wav",
                modelID: "bandit-continuous-v1",
                timelineStart: 117,
                timelineDuration: 306
            )
        ]

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(DubProject.self, from: data)
        #expect(decoded.preparedAudioAssets == project.preparedAudioAssets)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var assets = try #require(object["preparedAudioAssets"] as? [[String: Any]])
        assets[0].removeValue(forKey: "timelineStart")
        assets[0].removeValue(forKey: "timelineDuration")
        object["preparedAudioAssets"] = assets
        let oldContinuousData = try JSONSerialization.data(withJSONObject: object)
        let oldContinuous = try JSONDecoder().decode(DubProject.self, from: oldContinuousData)
        #expect(oldContinuous.preparedAudioAssets.first?.timelineStart == 0)
        #expect(oldContinuous.preparedAudioAssets.first?.timelineDuration == nil)

        object.removeValue(forKey: "preparedAudioAssets")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(DubProject.self, from: legacyData)
        #expect(legacy.preparedAudioAssets.isEmpty)
    }

    @Test func clipScopeAndPreparationPreferenceRoundTripAndMigrate() throws {
        var project = DubProject(name: "One Scene")
        project.mediaScope = .clip(start: 120, end: 420)
        project.settings.audioPreparationPreference = .cinematicSeparation

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(DubProject.self, from: data)
        #expect(decoded.mediaScope == project.mediaScope)
        #expect(decoded.settings.audioPreparationPreference == .cinematicSeparation)
        #expect(decoded.mediaScope.resolvedRange(sourceDuration: 7_200) == 120...420)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "mediaScope")
        var settings = try #require(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "audioPreparationPreference")
        object["settings"] = settings
        var assets = try #require(object["preparedAudioAssets"] as? [[String: Any]])
        if !assets.isEmpty {
            assets[0].removeValue(forKey: "timelineStart")
            assets[0].removeValue(forKey: "timelineDuration")
            object["preparedAudioAssets"] = assets
        }

        let legacy = try JSONDecoder().decode(
            DubProject.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.mediaScope == .fullMovie)
        #expect(legacy.settings.audioPreparationPreference == .automatic)
    }

    @Test func recognizesLikelyMusicAndEffectsTrackNames() {
        let candidates = ["M&E", "Music & Effects", "International Mix", "DME"]
        for title in candidates {
            let track = AudioTrackMetadata(
                id: title,
                title: title,
                languageCode: nil,
                codec: "pcm_s16le",
                channelCount: 6
            )
            #expect(track.isLikelyMusicAndEffects)
        }

        let commentary = AudioTrackMetadata(
            id: "commentary",
            title: "Director Commentary",
            languageCode: "eng",
            codec: "aac",
            channelCount: 2
        )
        #expect(!commentary.isLikelyMusicAndEffects)
    }

    @Test func cleaningPresetsDoNotOverSubtractDialogueWaveform() {
        for preset in DialogueCleaningPreset.allCases {
            #expect(preset.dialogueReduction == 1)
        }
        #expect(DialogueCleaningPreset.gentle.residualSuppressionStrength == 0)
        #expect(
            DialogueCleaningPreset.strong.residualSuppressionStrength
                > DialogueCleaningPreset.balanced.residualSuppressionStrength
        )
    }

    @Test func olderVideoReferenceRequiresPlaybackCacheUpgrade() throws {
        var project = DubProject(name: "Old Playback Cache")
        project.sourceVideo = SourceVideoReference(
            displayName: "movie.mkv",
            bookmarkData: Data([1, 2, 3]),
            lastKnownPath: "/Movies/movie.mkv",
            metadata: .empty,
            playbackFileName: "temp/source-playback.mov",
            playbackPreparationVersion: 2
        )
        let encoded = try JSONEncoder().encode(project)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var sourceVideo = try #require(object["sourceVideo"] as? [String: Any])
        sourceVideo.removeValue(forKey: "playbackPreparationVersion")
        object["sourceVideo"] = sourceVideo

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(DubProject.self, from: legacyData)

        #expect(decoded.sourceVideo?.playbackPreparationVersion == nil)
    }
}
