//
//  MenuItem.swift
//  FlowTrace
//
//  Created by f.zou on 2021/5/29.
//

import Foundation
import SwiftUI

struct MenuItem: View {
    let id: String
    /// Optional SF Symbol drawn before the label, sized with `.font` per the
    /// AGENTS.md rule on SF Symbols. `nil` (the default) renders text only,
    /// so existing call sites keep the old two-argument form.
    var icon: String? = nil
    let text: String
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13))
            }
            Text(text)
                .font(.system(size: 12, weight: .regular))
        }
        .foregroundColor(.gray)
        .contentShape(Rectangle())
        .animation(.none)
        .onTapGesture {
            action?()
        }
    }
}
