import AVFAudio
import Testing
@testable import LemonMusic

struct AudioSessionConfigurationTests {
    @MainActor @Test func playbackAudioSessionUsesValidCategoryOptions() throws {
        #expect(PlaybackController.audioSessionCategory == .playback)
        #expect(PlaybackController.audioSessionMode == .default)
        #expect(PlaybackController.audioSessionOptions.isEmpty)
        #expect(!PlaybackController.audioSessionOptions.contains(.allowAirPlay))
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            PlaybackController.audioSessionCategory,
            mode: PlaybackController.audioSessionMode,
            options: PlaybackController.audioSessionOptions
        )
        try session.setActive(true)
        #expect(session.category == .playback)
    }
}
