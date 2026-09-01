//
//  MenuItem.swift
//  iTrafficPlus
//
//  Created by f.zou on 2021/5/29.
//

import Foundation
import SwiftUI

struct MenuItem: View {
    let id: String
    let text: String
    var action: (() -> Void)?

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(.gray)
            .contentShape(Rectangle())
            .animation(.none)
            .onTapGesture {
                action?()
            }
    }
}

/// Icon-only sibling of `MenuItem`.
///
/// A plain `Text` glyph rather than an SF Symbol: the emoji renders identically
/// all the way back to 10.15, and a Unicode glyph never needs `.resizable()`,
/// which is what stretches SF Symbols into thin sticks at small sizes.
///
/// The upstream's `MenuIconItem` had exactly one caller — the Bytetally link
/// in the header — and that link was stripped when UpdateStatusView went away.
/// `MenuIconItem` is kept here in case a future experiment wants a glyph link;
/// it is currently unreferenced but builds clean.
struct MenuIconItem: View {
    let id: String
    let glyph: String
    var action: (() -> Void)?

    var body: some View {
        Text(glyph)
            .font(.system(size: 12))
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .animation(.none)
            .onTapGesture {
                action?()
            }
    }
}
