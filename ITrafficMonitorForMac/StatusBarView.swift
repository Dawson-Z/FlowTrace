//
//  StatusBarView.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//

import SwiftUI

struct StatusBarView: View {
    @StateObject var statusDataModel = SharedStore.statusDataModel
    // SettingsStore is observed so a toggle change in the Settings window
    // is reflected on the next redraw (which happens whenever the next
    // nettop frame arrives, ≤ 2 s). We do not need to repaint faster than
    // that — the status bar rates update on the same cadence.
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        HStack(alignment: .center) {
            VStack(spacing: 0) {
                Spacer().frame(width: 0, height: 1)

                if settings.showUploadInStatusBar {
                    HStack() {
                        Text("↗")
                            .font(.system(size: 9))
                        Text(formatBytes(bytes:statusDataModel.totalOutBytesPerSec))
                            .font(.system(size: 9))
                            .fontWeight(.medium)
                            .multilineTextAlignment(.trailing)
                            .padding(.leading, -8.0)
                            .frame(width: 45)
                    }.frame(width:60, height: 10, alignment: .trailing)
                }
                if settings.showDownloadInStatusBar {
                    HStack() {
                        Text("↙")
                            .font(.system(size: 9))
                            .multilineTextAlignment(.trailing)
                        Text(formatBytes(bytes:statusDataModel.totalInBytesPerSec))
                            .font(.system(size: 9))
                            .fontWeight(.medium)
                            .multilineTextAlignment(.trailing)
                            .padding(.leading, -8.0)
                            .frame(width: 45.0)
                    }.padding(.top, -1.5).frame(width:60, height: 10, alignment: .trailing)
                }
            }
        }
    }
}

struct StatusBarView_Previews: PreviewProvider {
    static var previews: some View {
        StatusBarView()
            .environment(\.sizeCategory, .small)
            
            
            
            
    }
}
