import Foundation

/// Compile-time feature switches. Keep these as the single gate for features that are built
/// but not yet shippable, so re-enabling is a one-line flip.
enum FeatureFlags {
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
}
