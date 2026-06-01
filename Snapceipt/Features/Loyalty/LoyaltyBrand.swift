import SwiftUI

/// A static loyalty-brand template. Picking one prefills brand/subBrand/colors on a
/// new card. `Custom` lets the user type a name (neutral gradient default).
struct LoyaltyBrand: Identifiable, Equatable {
    let key: String
    let name: String
    let subBrand: String?
    let color1: String   // hex "#RRGGBB"
    let color2: String   // hex "#RRGGBB"
    let monogram: String

    var id: String { key }

    /// SwiftUI colors parsed from the stored hex strings (same convention as ProfilesStore).
    var c1: Color { Color(hex: LoyaltyBrand.hex(color1)) }
    var c2: Color { Color(hex: LoyaltyBrand.hex(color2)) }

    static func hex(_ s: String) -> UInt32 {
        UInt32(s.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
    }

    /// The 9 seed AU brands (spec §4.5).
    static let catalog: [LoyaltyBrand] = [
        LoyaltyBrand(key: "everydayRewards", name: "Everyday Rewards", subBrand: "Woolworths",
                     color1: "#1A8A3C", color2: "#0C5C26", monogram: "ER"),
        LoyaltyBrand(key: "flybuys", name: "flybuys", subBrand: "Coles",
                     color1: "#1457C7", color2: "#0A2F86", monogram: "fb"),
        LoyaltyBrand(key: "myerOne", name: "MYER one", subBrand: nil,
                     color1: "#2C2C2C", color2: "#000000", monogram: "M"),
        LoyaltyBrand(key: "sisterClub", name: "Sister Club", subBrand: nil,
                     color1: "#D8467F", color2: "#A82C5E", monogram: "SC"),
        LoyaltyBrand(key: "qantasFF", name: "Qantas FF", subBrand: nil,
                     color1: "#E40000", color2: "#A30000", monogram: "Q"),
        LoyaltyBrand(key: "velocity", name: "Velocity", subBrand: nil,
                     color1: "#7A1FA2", color2: "#541570", monogram: "V"),
        LoyaltyBrand(key: "kmart", name: "Kmart", subBrand: nil,
                     color1: "#E51937", color2: "#B0122A", monogram: "K"),
        LoyaltyBrand(key: "bws", name: "BWS", subBrand: nil,
                     color1: "#0A7D3E", color2: "#06582B", monogram: "B"),
        LoyaltyBrand(key: "t2", name: "T2 Tea", subBrand: nil,
                     color1: "#1A1A1A", color2: "#000000", monogram: "T2"),
    ]

    /// The Custom path — a neutral dark gradient; name is supplied by the user.
    static let custom = LoyaltyBrand(key: "custom", name: "Custom", subBrand: nil,
                                     color1: "#3A3A3A", color2: "#1A1A1A", monogram: "+")
}
