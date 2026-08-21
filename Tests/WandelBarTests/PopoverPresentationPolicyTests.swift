import Testing
@testable import WandelBar

@Test func reopenShowsAHiddenPopover() {
    #expect(PopoverPresentationPolicy.action(for: .applicationReopen, isShown: false) == .show)
}

@Test func reopenFocusesAVisiblePopoverWithoutClosingIt() {
    #expect(PopoverPresentationPolicy.action(for: .applicationReopen, isShown: true) == .focus)
}

@Test func menuBarClickShowsAHiddenPopover() {
    #expect(PopoverPresentationPolicy.action(for: .menuBarClick, isShown: false) == .show)
}

@Test func menuBarClickClosesAVisiblePopover() {
    #expect(PopoverPresentationPolicy.action(for: .menuBarClick, isShown: true) == .close)
}

@Test func effectGroupsStartWithOnlyPanelExpanded() {
    let state = EffectGroupDisclosureState()

    #expect(state.isPanelExpanded)
    #expect(!state.isShadowExpanded)
    #expect(!state.isTintExpanded)
    #expect(!state.isTextureExpanded)
}

@Test func differingSpaceIndicatorRemainsVisibleWhileDefaultScopeIsSelected() {
    let presentation = ScopeCustomizationPresentation(
        scope: .global,
        hasSpaceOverride: true,
        isSpaceDifferentFromDefault: true
    )

    #expect(presentation.showsSpaceIndicator)
}

@Test func matchingExplicitSpaceHidesDifferenceIndicator() {
    let presentation = ScopeCustomizationPresentation(
        scope: .currentSpace,
        hasSpaceOverride: true,
        isSpaceDifferentFromDefault: false
    )

    #expect(!presentation.showsSpaceIndicator)
    #expect(presentation.canReset)
}

@Test func resetActionReflectsTheSelectedScope() {
    let inheritedSpace = ScopeCustomizationPresentation(
        scope: .currentSpace,
        hasSpaceOverride: false,
        isSpaceDifferentFromDefault: false
    )
    let customizedSpace = ScopeCustomizationPresentation(
        scope: .currentSpace,
        hasSpaceOverride: true,
        isSpaceDifferentFromDefault: true
    )
    let defaultScope = ScopeCustomizationPresentation(
        scope: .global,
        hasSpaceOverride: false,
        isSpaceDifferentFromDefault: false
    )

    #expect(!inheritedSpace.canReset)
    #expect(customizedSpace.canReset)
    #expect(customizedSpace.resetAccessibilityLabel == "Reset This Space to Default")
    #expect(defaultScope.canReset)
    #expect(defaultScope.resetAccessibilityLabel == "Reset Default Settings")
}

@Test func presetCatalogUsesItsOwnHeightWhileSettingsRemainContentSized() {
    #expect(PopoverContentSizing.fixedHeight(isPresetCatalogPresented: true) == 600)
    #expect(PopoverContentSizing.fixedHeight(isPresetCatalogPresented: false) == nil)
}

@Test func presetCatalogReplacesSettingsAsRootContent() {
    #expect(
        PopoverContentSizing.presentation(isPresetCatalogPresented: true)
            == .presetCatalog(height: 600)
    )
    #expect(
        PopoverContentSizing.presentation(isPresetCatalogPresented: false)
            == .settings
    )
}

@Test func spaceCustomizationIndicatorSitsBelowTheRightSegment() {
    let layout = ScopeCustomizationIndicatorLayout()
    let frame = layout.indicatorFrame(for: .init(width: 200, height: 30))

    #expect(frame.midX == 150)
    #expect(frame.minY > 30)
    #expect(frame.minX >= 100)
    #expect(frame.maxX <= 200)
    #expect(layout.bottomSpacing - (frame.maxY - 30) >= 8)
}

@Test func spaceApplicationToggleAlignsWithTheTrailingContentEdge() {
    let layout = SpaceApplicationRowLayout(availableWidth: 328)

    #expect(layout.toggleFrame == .init(x: 284, y: 0, width: 44, height: 24))
    #expect(layout.toggleFrame.maxX == 328)
}

@Test func spaceApplicationRowKeepsTheSameHeightInBothStates() {
    let layout = SpaceApplicationRowLayout(availableWidth: 328)

    #expect(layout.rowHeight(isEffectEnabled: true) == 24)
    #expect(layout.rowHeight(isEffectEnabled: false) == 24)
}
