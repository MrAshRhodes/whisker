/// User-facing choices, including commonly used variants of the same action family.
public enum ActionChoice: Hashable, Identifiable, Sendable {
    case family(ActionKind)
    case click(button: Int)
    case otherButtonClick
    case navigate(NavigationDirection)
    case missionControl(MissionControlTarget)

    public init(_ action: Action) {
        switch action {
        case .click(let button, _):
            self = (0...2).contains(button) ? .click(button: button) : .otherButtonClick
        case .navigate(let direction): self = .navigate(direction)
        case .missionControl(let target): self = .missionControl(target)
        default: self = .family(action.kind)
        }
    }

    public var id: Self { self }
    public var kind: ActionKind { defaultAction.kind }

    public var title: String {
        switch self {
        case .family(.media): return "Media, Volume or Brightness Key"
        case .family(let kind): return kind.title
        case .otherButtonClick: return "Other Button Click"
        default: return defaultAction.summary
        }
    }

    public var symbolName: String { defaultAction.symbolName }

    public var defaultAction: Action {
        switch self {
        case .family(let kind): return kind.defaultAction
        case .click(let button): return .click(button: button, modifiers: [])
        case .otherButtonClick: return .click(button: 3, modifiers: [])
        case .navigate(let direction): return .navigate(direction)
        case .missionControl(let target): return .missionControl(target)
        }
    }
}

public struct ActionMenuSection: Identifiable, Sendable {
    public let title: String?
    public let choices: [ActionChoice]
    public var id: String { title ?? "" }
}

public enum ActionMenu {
    public static let sections: [ActionMenuSection] = [
        .init(title: nil, choices: [.family(.passthrough), .family(.none)]),
        .init(title: "Click", choices: [
            .click(button: 0), .click(button: 1), .click(button: 2), .otherButtonClick,
            .family(.doubleClick), .family(.tripleClick), .family(.clickLock),
        ]),
        .init(title: "Navigate", choices: [
            .navigate(.back), .navigate(.forward), .family(.appSwitch), .family(.space),
        ]),
        .init(title: "Mission Control and Desktop", choices: MissionControlTarget.allCases.map {
            .missionControl($0)
        }),
        .init(title: "Keyboard and Media", choices: [
            .family(.shortcut), .family(.shortcutSequence), .family(.media),
        ]),
        .init(title: "Scroll", choices: [
            .family(.scroll), .family(.holdToScroll), .family(.autoScroll),
        ]),
        .init(title: "Pointer", choices: [.family(.slowPointer), .family(.pointerPreset)]),
        .init(title: "Open", choices: [.family(.open)]),
    ]

    public static var choices: [ActionChoice] { sections.flatMap(\.choices) }

    public static func sections(including isIncluded: (ActionChoice) -> Bool) -> [ActionMenuSection] {
        sections.compactMap { section in
            let choices = section.choices.filter(isIncluded)
            return choices.isEmpty ? nil : ActionMenuSection(title: section.title, choices: choices)
        }
    }
}
