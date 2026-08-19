//
//  AppLinks.swift
//  samplewebview
//

import Foundation

/// Built-in web destinations plus the parsing rules for links typed at runtime.
enum AppLinks {

    /// Visit Health SSO entry point for the NIVA_BUPA client. Kept as a
    /// convenience shortcut on the launcher screen; links can also be entered
    /// at runtime without rebuilding.
    static let ssoURLString = "https://niva-bupa-visit.getvisitapp.net/sso?userParams=sll51BZ45jruovK8dkRgTKHNSLtLxsWEhcDk11SwlFHcY-rXg9PVzoRcMHT9aq_uHh-VChBF47H6z3_ZeOopmgftLqrnkGrKVjRKdWHbdwd6ApCIrz1G2LuA_FX-FY6rU2keNam5dZyCsfIDpxxFT_5o1_6No--Nhhz78YFTP-Geqti4caXxGp2i4LPF9CpD-sj76CW470HxO_B50KP8BC_Til_JkKdqJTgC-2rf-mGElGwBSl_312hW74G88EJvh4Kc96G-yVAfIOnZHMglECrJpqk3Bl9UEkIIH3_t-pW4FG6cJJts41rU2xDel0pPYx_PCH4WZaoD1Bx3gC7waO6V9MNTb9s7l1mjIh-xjP5zAYEErSDKTf6KBLg5KnPr_8MHYruGwjG7tsmKHsaMbpDhgYFRlJGe02umqeLs8uJ_F4rS6Zz_hWqbb8O_LAPYJ5kzDFIBXmNSG77Jzhy6kcvAyUnSPjFOS2JkQQhhujseJ9FCAIhh7ACDHWk7ryDh&clientId=NIVA_BUPA"

    /// Force-unwrapped intentionally: the string above is a compile-time constant
    /// and a malformed value should surface immediately in development.
    static let sso = URL(string: ssoURLString)!

    /// Turns free-form typed or pasted text into a loadable web URL.
    ///
    /// - Whitespace and newlines are stripped throughout, because copying a long
    ///   SSO token out of a chat or email often introduces line breaks. Valid web
    ///   URLs never contain literal spaces, so this is safe.
    /// - A missing scheme is assumed to be `https`.
    /// - Only `http` and `https` are accepted; the WebView cannot load anything else.
    static func parse(_ text: String) -> URL? {
        let compacted = text.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !compacted.isEmpty else { return nil }

        let candidate = compacted.contains("://") ? compacted : "https://\(compacted)"

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }

        return url
    }
}
