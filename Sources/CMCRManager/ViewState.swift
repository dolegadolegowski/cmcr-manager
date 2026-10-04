import SwiftUI

/// `@State` through a type alias.
///
/// From the macOS 27 SDK on, `@State` is a macro whose compiler plugin ships only with Xcode. Referring to
/// the `State` property wrapper through an alias keeps the app buildable with just the Command Line Tools
/// while still linking against the newest SDK (and getting the current system look).
typealias ViewState<Value> = SwiftUI.State<Value>
