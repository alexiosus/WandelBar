import CoreGraphics

enum PopoverPresentationTrigger {
    case applicationReopen
    case menuBarClick
}

enum PopoverPresentationAction: Equatable {
    case show
    case focus
    case close
}

struct PopoverPresentationPolicy {
    static func action(
        for trigger: PopoverPresentationTrigger,
        isShown: Bool
    ) -> PopoverPresentationAction {
        switch (trigger, isShown) {
        case (.applicationReopen, false), (.menuBarClick, false):
            return .show
        case (.applicationReopen, true):
            return .focus
        case (.menuBarClick, true):
            return .close
        }
    }
}

struct EffectGroupDisclosureState: Equatable {
    var isPanelExpanded = true
    var isShadowExpanded = false
    var isTintExpanded = false
    var isTextureExpanded = false
}

struct ScopeCustomizationPresentation: Equatable {
    let scope: EffectScope
    let hasSpaceOverride: Bool
    let isSpaceDifferentFromDefault: Bool

    var showsSpaceIndicator: Bool {
        isSpaceDifferentFromDefault
    }

    var canReset: Bool {
        scope == .global || hasSpaceOverride
    }

    var resetAccessibilityLabel: String {
        switch scope {
        case .global:
            return "Reset Default Settings"
        case .currentSpace:
            return "Reset This Space to Default"
        }
    }
}

struct ScopeCustomizationIndicatorLayout {
    let width: CGFloat = 40
    let thickness: CGFloat = 3
    let gap: CGFloat = 4
    let bottomSpacing: CGFloat = 16

    func indicatorFrame(for pickerSize: CGSize) -> CGRect {
        CGRect(
            x: pickerSize.width * 0.75 - width / 2,
            y: pickerSize.height + gap,
            width: width,
            height: thickness
        )
    }
}

struct SpaceApplicationRowLayout {
    let availableWidth: CGFloat

    var toggleFrame: CGRect {
        CGRect(x: availableWidth - 44, y: 0, width: 44, height: 24)
    }

    func rowHeight(isEffectEnabled: Bool) -> CGFloat {
        24
    }
}

struct PopoverContentSizing {
    enum Presentation: Equatable {
        case settings
        case presetCatalog(height: CGFloat)
    }

    static func presentation(isPresetCatalogPresented: Bool) -> Presentation {
        isPresetCatalogPresented ? .presetCatalog(height: 600) : .settings
    }

    static func fixedHeight(isPresetCatalogPresented: Bool) -> CGFloat? {
        switch presentation(isPresetCatalogPresented: isPresetCatalogPresented) {
        case .settings:
            nil
        case .presetCatalog(let height):
            height
        }
    }
}
