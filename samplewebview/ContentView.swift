//
//  ContentView.swift
//  samplewebview
//
//  Created by Visit Health on 11/08/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        WebViewScreen(url: AppLinks.sso)
    }
}

#Preview {
    ContentView()
}
