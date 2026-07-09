import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("TranscriptHeuristic — speaker-name line density")
struct TranscriptHeuristicTests {

    private static let interviewTranscript = """
    Alice: Thanks for joining us today, I really appreciate it.

    Bob: Happy to be here, thanks for having me on the show.

    Alice: Let's start with your background — how did you get into this field?

    Bob: It's a long story, but the short version is I fell into it by accident.

    Alice: That's a great story. What do you think is the biggest misconception?

    Bob: People assume it's all glamorous, but most of the work is pretty mundane.

    Alice: Fair enough. Any final thoughts before we wrap up?

    Bob: Just that I'm grateful for the opportunity, thanks again.
    """

    private static let normalArticle = """
    ## Background

    This article explores the history of widget manufacturing in significant detail,
    covering the early days of hand assembly through to modern automation.

    Editor's note: this piece was updated in 2026 to reflect new manufacturing data.

    ## Modern Techniques

    Today's factories rely on a mix of robotics and skilled labor to produce
    widgets at scale, balancing cost against quality throughout the process.
    """

    @Test("A dialogue-heavy interview transcript looks like a transcript")
    func interviewLooksLikeTranscript() {
        #expect(TranscriptHeuristic.looksLikeTranscript(Self.interviewTranscript))
    }

    @Test("Speaker line density is high for the interview fixture")
    func interviewHasHighDensity() {
        let density = TranscriptHeuristic.speakerLineDensity(in: Self.interviewTranscript)
        #expect(density >= TranscriptHeuristic.minSpeakerLineDensity)
    }

    @Test("A normal article (with a single aside using a colon) does NOT look like a transcript")
    func normalArticleDoesNotLookLikeTranscript() {
        #expect(!TranscriptHeuristic.looksLikeTranscript(Self.normalArticle))
    }

    @Test("Empty text does not look like a transcript")
    func emptyTextDoesNotLookLikeTranscript() {
        #expect(!TranscriptHeuristic.looksLikeTranscript(""))
        #expect(TranscriptHeuristic.speakerLineDensity(in: "") == 0)
    }

    @Test("A short dialogue snippet under the minimum line count is NOT flagged")
    func tooFewLinesNotFlagged() {
        let short = "Alice: Hi there.\n\nBob: Hello!"
        #expect(!TranscriptHeuristic.looksLikeTranscript(short))
    }

    @Test("A timestamped speaker line ([HH:MM:SS] Name:) is recognized")
    func timestampedSpeakerLineRecognized() {
        #expect(TranscriptHeuristic.isSpeakerLine("[00:01:23] Alice: Let's begin."))
        #expect(TranscriptHeuristic.isSpeakerLine("[01:02] Bob: Sounds good."))
    }
}
