//
//  AccessibilityElementSnapper.swift
//  leanring-buddy
//
//  Snaps the coordinate Claude points at to the nearest real interactive UI
//  element (button, menu item, text field, ...) using the macOS Accessibility
//  API. Claude reads coordinates off a downscaled screenshot, so its guesses
//  often land a few points beside small controls. The Accessibility tree
//  knows the exact frame of every control, so we use it to correct the aim.
//  Runs entirely on-device and costs nothing.
//

import AppKit
import ApplicationServices

/// An interactive element found near the point Claude asked us to point at.
struct AccessibilitySnappedElement {
    /// Center of the element in AppKit global coordinates (bottom-left origin),
    /// ready to hand to the cursor overlay.
    let elementCenterInAppKitGlobalCoordinates: CGPoint
    let elementFrameInAppKitGlobalCoordinates: CGRect
    let elementRole: String
    let elementTitle: String?
    /// 0 when Claude's point was already inside the element.
    let distanceFromRequestedPointInPoints: CGFloat
}

enum AccessibilityElementSnapper {
    /// How far (in points) from Claude's point we'll look for a control.
    /// Large enough to absorb screenshot-downscaling error, small enough that
    /// we don't jump to an unrelated neighbouring button.
    private static let maximumSnapDistanceInPoints: CGFloat = 48

    /// Elements bigger than this are areas (editors, canvases, sidebars), not
    /// controls. Snapping to their center would move the cursor *away* from
    /// the specific spot Claude meant, so we leave those points alone.
    private static let maximumSnappableElementWidthInPoints: CGFloat = 500
    private static let maximumSnappableElementHeightInPoints: CGFloat = 150

    /// Caps on the tree walk so a huge or slow app can't stall the response.
    private static let maximumElementsToVisit = 2500
    private static let maximumSearchDurationSeconds: TimeInterval = 0.25

    /// Per-element IPC timeout. Without this a hung app can block an
    /// Accessibility call for ~6 seconds (the system default).
    private static let perElementMessagingTimeoutSeconds: Float = 0.1

    /// How many parents to walk up from the hit-tested element when looking
    /// for the control that contains it (e.g. a label inside a button).
    private static let maximumAncestorLevelsToWalk = 5

    private static let interactiveRoles: Set<String> = [
        kAXButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXPopUpButtonRole as String,
        kAXMenuButtonRole as String,
        kAXMenuBarItemRole as String,
        kAXMenuItemRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        kAXSliderRole as String,
        kAXIncrementorRole as String,
        kAXDisclosureTriangleRole as String,
        kAXColorWellRole as String,
        "AXLink",
        "AXSegment"
    ]

    /// Roles that are never a sensible pointing target even if they
    /// technically expose a press action.
    private static let containerRolesToNeverSnapTo: Set<String> = [
        kAXApplicationRole as String,
        kAXWindowRole as String,
        kAXSheetRole as String,
        kAXDrawerRole as String,
        kAXScrollAreaRole as String,
        kAXSplitGroupRole as String,
        kAXListRole as String,
        kAXOutlineRole as String,
        kAXTableRole as String,
        kAXBrowserRole as String,
        kAXMenuBarRole as String,
        kAXMenuRole as String,
        kAXToolbarRole as String,
        kAXTabGroupRole as String,
        "AXWebArea"
    ]

    /// Hit-test roles that mean Claude's point fell between controls rather
    /// than on something specific, so it's worth searching nearby.
    private static let emptySpaceRoles: Set<String> = containerRolesToNeverSnapTo.union([
        kAXGroupRole as String,
        kAXUnknownRole as String,
        kAXLayoutAreaRole as String
    ])

    /// Returns the nearest interactive element to `requestedAppKitGlobalPoint`,
    /// or nil when Accessibility permission is missing or nothing suitable is
    /// close enough (in which case callers should keep Claude's original point).
    @MainActor
    static func findNearestInteractiveElement(
        nearAppKitGlobalPoint requestedAppKitGlobalPoint: CGPoint
    ) async -> AccessibilitySnappedElement? {
        guard WindowPositionManager.hasAccessibilityPermission() else { return nil }

        // AppKit global coordinates have their origin at the bottom-left of the
        // primary display with y pointing up. Accessibility uses the top-left
        // of the primary display with y pointing down.
        guard let primaryDisplayHeight = NSScreen.screens.first?.frame.height else { return nil }

        let requestedAccessibilityPoint = CGPoint(
            x: requestedAppKitGlobalPoint.x,
            y: primaryDisplayHeight - requestedAppKitGlobalPoint.y
        )
        let clickyProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let frontmostApplicationProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Accessibility calls are synchronous IPC into other apps, so keep
        // them off the main thread to avoid freezing the overlay animation.
        let nearestElementCandidate = await Task.detached(priority: .userInitiated) {
            Self.searchForNearestInteractiveElement(
                requestedAccessibilityPoint: requestedAccessibilityPoint,
                clickyProcessIdentifier: clickyProcessIdentifier,
                frontmostApplicationProcessIdentifier: frontmostApplicationProcessIdentifier
            )
        }.value

        guard let nearestElementCandidate else { return nil }

        let elementFrameInAppKitGlobalCoordinates = CGRect(
            x: nearestElementCandidate.frameInAccessibilityCoordinates.origin.x,
            y: primaryDisplayHeight - nearestElementCandidate.frameInAccessibilityCoordinates.maxY,
            width: nearestElementCandidate.frameInAccessibilityCoordinates.width,
            height: nearestElementCandidate.frameInAccessibilityCoordinates.height
        )

        return AccessibilitySnappedElement(
            elementCenterInAppKitGlobalCoordinates: CGPoint(
                x: elementFrameInAppKitGlobalCoordinates.midX,
                y: elementFrameInAppKitGlobalCoordinates.midY
            ),
            elementFrameInAppKitGlobalCoordinates: elementFrameInAppKitGlobalCoordinates,
            elementRole: nearestElementCandidate.role,
            elementTitle: nearestElementCandidate.title,
            distanceFromRequestedPointInPoints: nearestElementCandidate.distanceFromRequestedPointInPoints
        )
    }

    // MARK: - Search

    private struct InteractiveElementCandidate {
        let frameInAccessibilityCoordinates: CGRect
        let role: String
        let title: String?
        let distanceFromRequestedPointInPoints: CGFloat
    }

    private static func searchForNearestInteractiveElement(
        requestedAccessibilityPoint: CGPoint,
        clickyProcessIdentifier: pid_t,
        frontmostApplicationProcessIdentifier: pid_t?
    ) -> InteractiveElementCandidate? {
        var applicationProcessIdentifierToSearch = frontmostApplicationProcessIdentifier

        // Fast path: ask the system which element is directly under the point
        // and walk up to the control that contains it. This handles the common
        // case where Claude's point already lands on the control or its label.
        let systemWideElement = AXUIElementCreateSystemWide()
        var hitTestedElement: AXUIElement?
        let hitTestResult = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(requestedAccessibilityPoint.x),
            Float(requestedAccessibilityPoint.y),
            &hitTestedElement
        )

        if hitTestResult == .success, let hitTestedElement {
            var hitTestedProcessIdentifier: pid_t = 0
            let didReadProcessIdentifier = AXUIElementGetPid(hitTestedElement, &hitTestedProcessIdentifier) == .success

            // Our own cursor overlay can sit on top of everything; ignore it
            // and fall through to searching the app underneath instead.
            if didReadProcessIdentifier && hitTestedProcessIdentifier != clickyProcessIdentifier {
                if let containingInteractiveElement = findInteractiveAncestorContainingPoint(
                    startingAt: hitTestedElement,
                    requestedAccessibilityPoint: requestedAccessibilityPoint
                ) {
                    return containingInteractiveElement
                }

                // If the point landed on real content (an editor, an image, a
                // label), Claude meant that spot. Searching nearby would drag the
                // cursor onto some neighbouring button, so keep Claude's point.
                let hitTestedRole = copyStringAttribute(hitTestedElement, attributeName: kAXRoleAttribute as String)
                let didLandInEmptySpace = hitTestedRole.map { emptySpaceRoles.contains($0) } ?? true
                guard didLandInEmptySpace else { return nil }

                applicationProcessIdentifierToSearch = hitTestedProcessIdentifier
            }
        }

        // Slow path: Claude's point landed in a gap between controls (or on a
        // container). Search that app's tree for the closest control nearby.
        guard let applicationProcessIdentifierToSearch,
              applicationProcessIdentifierToSearch != clickyProcessIdentifier else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(applicationProcessIdentifierToSearch)
        return findNearestInteractiveElementInTree(
            rootElement: applicationElement,
            requestedAccessibilityPoint: requestedAccessibilityPoint
        )
    }

    private static func findInteractiveAncestorContainingPoint(
        startingAt hitTestedElement: AXUIElement,
        requestedAccessibilityPoint: CGPoint
    ) -> InteractiveElementCandidate? {
        var currentElement: AXUIElement? = hitTestedElement

        for _ in 0..<maximumAncestorLevelsToWalk {
            guard let elementToInspect = currentElement else { return nil }
            AXUIElementSetMessagingTimeout(elementToInspect, perElementMessagingTimeoutSeconds)

            if let candidate = makeCandidateIfSnappable(
                element: elementToInspect,
                requestedAccessibilityPoint: requestedAccessibilityPoint
            ) {
                return candidate
            }

            currentElement = copyElementAttribute(elementToInspect, attributeName: kAXParentAttribute as String)
        }

        return nil
    }

    /// Breadth-first walk that only descends into elements whose frame
    /// overlaps the search area, so we skip almost all of a large app's tree.
    private static func findNearestInteractiveElementInTree(
        rootElement: AXUIElement,
        requestedAccessibilityPoint: CGPoint
    ) -> InteractiveElementCandidate? {
        let searchArea = CGRect(
            x: requestedAccessibilityPoint.x - maximumSnapDistanceInPoints,
            y: requestedAccessibilityPoint.y - maximumSnapDistanceInPoints,
            width: maximumSnapDistanceInPoints * 2,
            height: maximumSnapDistanceInPoints * 2
        )
        let searchDeadline = Date().addingTimeInterval(maximumSearchDurationSeconds)

        var elementsWaitingToBeVisited: [AXUIElement] = [rootElement]
        var nextElementIndexToVisit = 0
        var bestCandidateSoFar: InteractiveElementCandidate?

        while nextElementIndexToVisit < elementsWaitingToBeVisited.count
                && nextElementIndexToVisit < maximumElementsToVisit
                && Date() < searchDeadline {
            let elementToInspect = elementsWaitingToBeVisited[nextElementIndexToVisit]
            nextElementIndexToVisit += 1
            AXUIElementSetMessagingTimeout(elementToInspect, perElementMessagingTimeoutSeconds)

            // Elements without a frame (the application itself, some groups)
            // can still contain on-screen children, so always descend into them.
            if let elementFrame = copyElementFrame(elementToInspect) {
                guard elementFrame.intersects(searchArea) else { continue }

                if let candidate = makeCandidateIfSnappable(
                    element: elementToInspect,
                    requestedAccessibilityPoint: requestedAccessibilityPoint
                ) {
                    if isCandidate(candidate, betterThan: bestCandidateSoFar) {
                        bestCandidateSoFar = candidate
                    }
                }
            }

            if let childElements = copyChildElements(elementToInspect) {
                elementsWaitingToBeVisited.append(contentsOf: childElements)
            }
        }

        return bestCandidateSoFar
    }

    /// Closest wins. When the point is inside several nested controls,
    /// the smaller (more specific) one wins.
    private static func isCandidate(
        _ newCandidate: InteractiveElementCandidate,
        betterThan currentBestCandidate: InteractiveElementCandidate?
    ) -> Bool {
        guard let currentBestCandidate else { return true }

        if newCandidate.distanceFromRequestedPointInPoints != currentBestCandidate.distanceFromRequestedPointInPoints {
            return newCandidate.distanceFromRequestedPointInPoints < currentBestCandidate.distanceFromRequestedPointInPoints
        }

        let newCandidateArea = newCandidate.frameInAccessibilityCoordinates.width * newCandidate.frameInAccessibilityCoordinates.height
        let currentBestCandidateArea = currentBestCandidate.frameInAccessibilityCoordinates.width * currentBestCandidate.frameInAccessibilityCoordinates.height
        return newCandidateArea < currentBestCandidateArea
    }

    private static func makeCandidateIfSnappable(
        element: AXUIElement,
        requestedAccessibilityPoint: CGPoint
    ) -> InteractiveElementCandidate? {
        guard let elementRole = copyStringAttribute(element, attributeName: kAXRoleAttribute as String) else {
            return nil
        }
        guard !containerRolesToNeverSnapTo.contains(elementRole) else { return nil }

        guard let elementFrame = copyElementFrame(element),
              elementFrame.width > 1,
              elementFrame.height > 1,
              elementFrame.width <= maximumSnappableElementWidthInPoints,
              elementFrame.height <= maximumSnappableElementHeightInPoints else {
            return nil
        }

        let distanceFromRequestedPoint = distanceFromPoint(requestedAccessibilityPoint, toRectangle: elementFrame)
        guard distanceFromRequestedPoint <= maximumSnapDistanceInPoints else { return nil }

        // Checked last because reading actions is an extra IPC round trip.
        let isInteractive = interactiveRoles.contains(elementRole) || elementSupportsPressAction(element)
        guard isInteractive else { return nil }

        let elementTitle = copyStringAttribute(element, attributeName: kAXTitleAttribute as String)
            ?? copyStringAttribute(element, attributeName: kAXDescriptionAttribute as String)

        return InteractiveElementCandidate(
            frameInAccessibilityCoordinates: elementFrame,
            role: elementRole,
            title: elementTitle,
            distanceFromRequestedPointInPoints: distanceFromRequestedPoint
        )
    }

    /// Shortest distance from a point to the edge of a rectangle (0 if inside).
    private static func distanceFromPoint(_ point: CGPoint, toRectangle rectangle: CGRect) -> CGFloat {
        let horizontalDistance = max(rectangle.minX - point.x, 0, point.x - rectangle.maxX)
        let verticalDistance = max(rectangle.minY - point.y, 0, point.y - rectangle.maxY)
        return (horizontalDistance * horizontalDistance + verticalDistance * verticalDistance).squareRoot()
    }

    // MARK: - Accessibility attribute helpers

    private static func copyAttributeValue(_ element: AXUIElement, attributeName: String) -> CFTypeRef? {
        var attributeValue: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue)
        guard copyResult == .success else { return nil }
        return attributeValue
    }

    private static func copyStringAttribute(_ element: AXUIElement, attributeName: String) -> String? {
        guard let stringValue = copyAttributeValue(element, attributeName: attributeName) as? String,
              !stringValue.isEmpty else {
            return nil
        }
        return stringValue
    }

    private static func copyElementAttribute(_ element: AXUIElement, attributeName: String) -> AXUIElement? {
        guard let attributeValue = copyAttributeValue(element, attributeName: attributeName),
              CFGetTypeID(attributeValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (attributeValue as! AXUIElement)
    }

    private static func copyChildElements(_ element: AXUIElement) -> [AXUIElement]? {
        copyAttributeValue(element, attributeName: kAXChildrenAttribute as String) as? [AXUIElement]
    }

    /// Frame in Accessibility coordinates (top-left origin of the primary display).
    private static func copyElementFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionAttributeValue = copyAttributeValue(element, attributeName: kAXPositionAttribute as String),
              let sizeAttributeValue = copyAttributeValue(element, attributeName: kAXSizeAttribute as String),
              CFGetTypeID(positionAttributeValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeAttributeValue) == AXValueGetTypeID() else {
            return nil
        }

        var elementPosition = CGPoint.zero
        var elementSize = CGSize.zero
        guard AXValueGetValue(positionAttributeValue as! AXValue, .cgPoint, &elementPosition),
              AXValueGetValue(sizeAttributeValue as! AXValue, .cgSize, &elementSize) else {
            return nil
        }

        return CGRect(origin: elementPosition, size: elementSize)
    }

    private static func elementSupportsPressAction(_ element: AXUIElement) -> Bool {
        var actionNames: CFArray?
        guard AXUIElementCopyActionNames(element, &actionNames) == .success,
              let actionNameList = actionNames as? [String] else {
            return false
        }
        return actionNameList.contains(kAXPressAction as String)
    }
}
