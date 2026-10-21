
import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins
import QuartzCore


public enum VariableBlurDirection {
    case blurredTopClearBottom
    case blurredBottomClearTop
}

/// How the blur radius changes between the clear edge and the fully blurred edge.
public enum VariableBlurCurve {
    /// The radius changes at a constant rate.
    case linear
    /// The radius eases in and out (a smoothstep), so the start of the blur is harder to see.
    case smooth
}


public struct VariableBlurView: UIViewRepresentable {

    public var maxBlurRadius: CGFloat = 20

    public var direction: VariableBlurDirection = .blurredTopClearBottom

    /// By default, variable blur starts from 0 blur radius and linearly increases to `maxBlurRadius`. Setting `startOffset` to a small negative coefficient (e.g. -0.1) will start blur from larger radius value which might look better in some cases.
    public var startOffset: CGFloat = 0

    /// How the radius changes from the clear edge to the blurred edge.
    public var curve: VariableBlurCurve = .linear

    public init(
        maxBlurRadius: CGFloat = 20,
        direction: VariableBlurDirection = .blurredTopClearBottom,
        startOffset: CGFloat = 0,
        curve: VariableBlurCurve = .linear
    ) {
        self.maxBlurRadius = maxBlurRadius
        self.direction = direction
        self.startOffset = startOffset
        self.curve = curve
    }

    public func makeUIView(context: Context) -> VariableBlurUIView {
        VariableBlurUIView(maxBlurRadius: maxBlurRadius, direction: direction, startOffset: startOffset, curve: curve)
    }

    public func updateUIView(_ uiView: VariableBlurUIView, context: Context) {
    }
}


/// credit https://github.com/jtrivedi/VariableBlurView
///
/// This relies on a private Core Animation filter. If the filter can't be created (for example because a future iOS
/// removed it), the view draws no blur at all rather than crashing. With Reduce Transparency on, it shows the plain
/// system blur material instead, which iOS draws as a solid panel.
open class VariableBlurUIView: UIVisualEffectView {

    private let maxBlurRadius: CGFloat
    private let direction: VariableBlurDirection
    private let startOffset: CGFloat
    private let curve: VariableBlurCurve

    /// Shared, because creating a `CIContext` is expensive and the mask is only a tiny image.
    private static let ciContext = CIContext()

    public init(
        maxBlurRadius: CGFloat = 20,
        direction: VariableBlurDirection = .blurredTopClearBottom,
        startOffset: CGFloat = 0,
        curve: VariableBlurCurve = .linear
    ) {
        self.maxBlurRadius = maxBlurRadius
        self.direction = direction
        self.startOffset = startOffset
        self.curve = curve
        super.init(effect: nil)

        configure()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceTransparencyChanged),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            object: nil
        )
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    open override func didMoveToWindow() {
        // fixes visible pixelization at unblurred edge (https://github.com/nikstar/VariableBlur/issues/1)
        guard let window, let backdropLayer = subviews.first?.layer else { return }
        backdropLayer.setValue(window.traitCollection.displayScale, forKey: "scale")
    }

    open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        // `super.traitCollectionDidChange(previousTraitCollection)` crashes the app
    }

    @objc private func reduceTransparencyChanged() {
        configure()
        didMoveToWindow()
    }

    /// Builds the effect for the current accessibility setting, replacing whatever was there.
    private func configure() {
        // Start from a fresh effect view, so switching back from the variable blur restores the system filters.
        effect = nil

        // The system turns its blur material into a solid panel when Reduce Transparency is on.
        if UIAccessibility.isReduceTransparencyEnabled {
            effect = UIBlurEffect(style: .regular)
            return
        }

        guard
            let variableBlur = Self.makeVariableBlurFilter(),
            let gradientImage = makeGradientImage()
        else {
            // No blur, rather than a crash or an unrelated uniform blur.
            return
        }

        effect = UIBlurEffect(style: .regular)

        // The blur radius at each pixel depends on the alpha value of the corresponding pixel in the gradient mask.
        // An alpha of 1 results in the max blur radius, while an alpha of 0 is completely unblurred.
        variableBlur.setValue(maxBlurRadius, forKey: "inputRadius")
        variableBlur.setValue(gradientImage, forKey: "inputMaskImage")
        variableBlur.setValue(true, forKey: "inputNormalizeEdges")

        // We use a `UIVisualEffectView` here purely to get access to its `CABackdropLayer`,
        // which is able to apply various, real-time CAFilters onto the views underneath.
        let backdropLayer = subviews.first?.layer

        // Replace the standard filters (i.e. `gaussianBlur`, `colorSaturate`, etc.) with only the variableBlur.
        backdropLayer?.filters = [variableBlur]

        // Get rid of the visual effect view's dimming/tint view, so we don't see a hard line.
        for subview in subviews.dropFirst() {
            subview.alpha = 0
        }
    }

    /// Creates the private variable blur filter, or nil if it isn't available.
    private static func makeVariableBlurFilter() -> NSObject? {
        let clsName = String("retliFAC".reversed())
        guard let Cls = NSClassFromString(clsName) as? NSObject.Type else {
            print("[VariableBlur] Error: Can't find filter class")
            return nil
        }
        let selector = NSSelectorFromString(String(":epyThtiWretlif".reversed()))
        guard
            Cls.responds(to: selector),
            let variableBlur = Cls.perform(selector, with: "variableBlur")?.takeUnretainedValue() as? NSObject
        else {
            print("[VariableBlur] Error: Can't create variableBlur filter")
            return nil
        }
        return variableBlur
    }

    private func makeGradientImage(width: CGFloat = 100, height: CGFloat = 100) -> CGImage? { // much lower resolution might be acceptable
        var point0 = CGPoint(x: 0, y: height)
        var point1 = CGPoint(x: 0, y: startOffset * height) // small negative value looks better with vertical lines
        if case .blurredBottomClearTop = direction {
            point0.y = 0
            point1.y = height - point1.y
        }

        let output: CIImage?
        switch curve {
        case .linear:
            let gradient = CIFilter.linearGradient()
            gradient.color0 = CIColor.black
            gradient.color1 = CIColor.clear
            gradient.point0 = point0
            gradient.point1 = point1
            output = gradient.outputImage
        case .smooth:
            let gradient = CIFilter.smoothLinearGradient()
            gradient.color0 = CIColor.black
            gradient.color1 = CIColor.clear
            gradient.point0 = point0
            gradient.point1 = point1
            output = gradient.outputImage
        }
        return output.flatMap { Self.ciContext.createCGImage($0, from: CGRect(x: 0, y: 0, width: width, height: height)) }
    }
}
