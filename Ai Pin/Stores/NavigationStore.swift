import SwiftUI
import AppIntents

@Observable final class NavigationStore: @unchecked Sendable {
    var selectedTab: Tab = .notes
    
    var notesNavigationPath = NavigationPath()
    
    var authenticationPresented = false
    var composerNote: Note?
    var isWifiPresented = false
    
    var textColorPresented = false
    var iconChangerPresented = false
}


enum Tab: String, AppEnum {
    case notes
    case captures
    case myData
    case settings
    case contacts
    
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "App Tab"
    static var caseDisplayRepresentations: [Tab: DisplayRepresentation] = [
        .notes: "Notes",
        .captures: "Captures",
        .myData: "My Data",
        .settings: "Settings",
        .contacts: "Contacts"
    ]
}
