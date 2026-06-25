import PunkRecordsCore

/// Disambiguates the unqualified name `Document` within the app module.
///
/// The macOS 26+ SDK added `public protocol SwiftUI.Document`, which collides
/// with our model type `PunkRecordsCore.Document` in every view that imports
/// both SwiftUI and PunkRecordsCore. A module-level declaration in the current
/// module takes precedence over imported names during unqualified lookup, so
/// this typealias makes bare `Document` resolve to our model everywhere in the
/// app without touching each use site.
typealias Document = PunkRecordsCore.Document
