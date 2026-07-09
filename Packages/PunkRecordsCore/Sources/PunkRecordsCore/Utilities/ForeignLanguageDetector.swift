import Foundation

/// Detects a non-target-language page, per PUNK-zup's failure mode #8: prefer
/// the page's own `<html lang>` attribute; fall back to an on-device language
/// recognizer's guess (Infra: `NLLanguageRecognizer`, run against the
/// extracted body and passed in via ``URLIngestSignals/languageRecognizerHint``)
/// when the page has no `lang` attribute. Pure string comparison — Core never
/// runs the recognizer itself.
public enum ForeignLanguageDetector {
    /// The language treated as "not foreign" — no hint is produced when the
    /// detected language matches this on its primary subtag (so `"en-US"`/
    /// `"en-GB"` both count as `"en"`, not foreign).
    public static let targetLanguageCode = "en"

    /// Detect a ``LanguageHint`` from `signals`, or `nil` when the page is
    /// (probably) in `targetLanguageCode`, or when no language signal is
    /// available at all.
    public static func detect(
        signals: URLIngestSignals,
        policy: ForeignLanguagePolicy = .default,
        targetLanguageCode: String = ForeignLanguageDetector.targetLanguageCode
    ) -> LanguageHint? {
        guard let code = primarySubtag(signals.htmlLangAttribute) ?? primarySubtag(signals.languageRecognizerHint) else {
            return nil
        }
        guard code != targetLanguageCode.lowercased() else { return nil }
        return LanguageHint(languageCode: code, policy: policy)
    }

    /// The lowercased primary subtag of a BCP-47-ish code (`"en-US"` →
    /// `"en"`). `nil` for blank/whitespace-only/`"und"` (undetermined) input.
    static func primarySubtag(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed != "und" else { return nil }
        return trimmed.split(separator: "-").first.map(String.init)
    }
}
