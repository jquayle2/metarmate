import Foundation

/// Compile-time feature switches. Keep these as the single gate for features that are built
/// but not yet shippable, so re-enabling is a one-line flip. Compiled into the app AND the widget
/// extension, so both always read the same values.
nonisolated enum FeatureFlags {
    /// The one Pro gating switch (A3, approved Oct 23). App Store (Release) and Debug builds: on.
    /// TestFlight builds: off, so beta testers keep every feature, until Jeff flips the TESTFLIGHT
    /// line. The TESTFLIGHT condition is set on the TestFlight configuration of every target,
    /// widget included.
    #if TESTFLIGHT
    static let proGatingEnabled = false
    #else
    static let proGatingEnabled = true
    #endif

    /// ASOS 5-minute updates. The subscription products were dropped and the data layer is off
    /// until funded later, so every path that would let a user buy/subscribe to ASOS — the
    /// detail-view teaser and thus the ASOS paywall it opens — must stay hidden. The ASOS code
    /// (decodedASOSSection, SynopticService, StoreManager ASOS logic) is kept intact behind this
    /// flag; flip to `true` to bring the offer back. See XW_REVERT_TOGGLE_BRIEF.
    static let asosAvailable = false

    /// Favorites pro-gate. The subscription products were dropped, so Favorites is free for now
    /// (no paywall). The gating code in FavoritesView is kept intact — flip to `true` to put
    /// Favorites back behind a pro purchase.
    static let favoritesRequirePro = false

    /// Widgets + Siri pro-gate. Defined in `WidgetDataManager.widgetsRequirePro` because that
    /// file is shared with the widget extension target; mirrored here for discoverability.
    static var widgetsRequirePro: Bool { WidgetDataManager.widgetsRequirePro }
}
