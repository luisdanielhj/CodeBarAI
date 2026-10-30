import SwiftUI

/// Keep account badges within the original logo's footprint. The numeral is
/// cut out of the alpha mask so macOS can tint the template in either theme.
struct MenuBarProviderLogo: View {
    let logoName: String
    let accountNumber: Int?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(logoName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
            if let accountNumber {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.black)
                    .frame(width: 8, height: 9)
                Text(String(accountNumber))
                    .font(.system(size: 7, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(.black)
                    .frame(width: 8, height: 9)
                    .blendMode(.destinationOut)
            }
        }
        .foregroundStyle(.black)
        .frame(width: 14, height: 14)
        .compositingGroup()
    }
}
