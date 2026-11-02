import SwiftUI

/// The Command Line Tools SDK declares `@State` as a macro whose implementation
/// (SwiftUIMacros) ships only with Xcode, so `@State` fails to expand in a
/// CLT-only build. This alias refers to the `State` property wrapper itself,
/// which behaves identically and builds with either toolchain.
typealias ViewState<Value> = SwiftUI.State<Value>
