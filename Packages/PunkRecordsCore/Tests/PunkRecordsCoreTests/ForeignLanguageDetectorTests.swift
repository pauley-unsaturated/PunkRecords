import Testing
import Foundation
@testable import PunkRecordsCore

@Suite("ForeignLanguageDetector — html lang attribute with NLLanguageRecognizer fallback")
struct ForeignLanguageDetectorTests {

    private func signals(lang: String? = nil, fallback: String? = nil) -> URLIngestSignals {
        URLIngestSignals(
            requestedURL: URL(string: "https://example.com/post")!,
            htmlLangAttribute: lang,
            languageRecognizerHint: fallback
        )
    }

    @Test("A French lang attribute produces a foreign-language hint")
    func frenchDetected() {
        let hint = ForeignLanguageDetector.detect(signals: signals(lang: "fr"))
        #expect(hint?.languageCode == "fr")
    }

    @Test("A region-qualified English lang attribute (en-GB) is NOT foreign")
    func englishRegionVariantNotForeign() {
        #expect(ForeignLanguageDetector.detect(signals: signals(lang: "en-GB")) == nil)
    }

    @Test("Falls back to the language-recognizer hint when lang attribute is absent")
    func fallsBackToRecognizerHint() {
        let hint = ForeignLanguageDetector.detect(signals: signals(lang: nil, fallback: "de"))
        #expect(hint?.languageCode == "de")
    }

    @Test("An explicit lang attribute takes priority over the recognizer fallback")
    func langAttributeTakesPriority() {
        let hint = ForeignLanguageDetector.detect(signals: signals(lang: "ja", fallback: "en"))
        #expect(hint?.languageCode == "ja")
    }

    @Test("No lang attribute and no recognizer hint produces no language signal at all")
    func noSignalProducesNilHint() {
        #expect(ForeignLanguageDetector.detect(signals: signals()) == nil)
    }

    @Test("An 'und' (undetermined) lang attribute is treated as no signal")
    func undeterminedIsIgnored() {
        #expect(ForeignLanguageDetector.detect(signals: signals(lang: "und")) == nil)
    }

    @Test("The default policy is summarizeInSourceLanguage")
    func defaultPolicyIsSourceLanguage() {
        let hint = ForeignLanguageDetector.detect(signals: signals(lang: "es"))
        #expect(hint?.policy == .summarizeInSourceLanguage)
    }

    @Test("A caller can override the policy to translateThenSummarize")
    func policyOverride() {
        let hint = ForeignLanguageDetector.detect(signals: signals(lang: "es"), policy: .translateThenSummarize)
        #expect(hint?.policy == .translateThenSummarize)
    }

    @Test("A caller can override the target language code")
    func customTargetLanguage() {
        // If the "home" language were French, a French page is not foreign.
        #expect(ForeignLanguageDetector.detect(signals: signals(lang: "fr"), targetLanguageCode: "fr") == nil)
        // ...but an English page now IS foreign relative to that target.
        #expect(ForeignLanguageDetector.detect(signals: signals(lang: "en"), targetLanguageCode: "fr") != nil)
    }
}
