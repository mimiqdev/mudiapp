import UIKit

/// Visual key caps sit inside separate, non-overlapping 44pt controls.
final class MudiKeyButton: UIButton {
    let cap = UIView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        cap.isUserInteractionEnabled = false
        insertSubview(cap, at: 0)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
                                     heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
        titleLabel?.adjustsFontForContentSizeCategory = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        cap.frame = bounds.insetBy(dx: 4, dy: 5)
        if let imageView { bringSubviewToFront(imageView) }
        if let titleLabel { bringSubviewToFront(titleLabel) }
    }
}

final class MudiKeyScrollView: UIScrollView {
    private let fade = CAGradientLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = fade
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = bounds
        let edge = min(22 / max(bounds.width, 1), 0.49)
        let left = contentOffset.x > 0.5
        let right = contentOffset.x + bounds.width < contentSize.width - 0.5
        fade.colors = [(left ? UIColor.clear : .white).cgColor, UIColor.white.cgColor,
                       UIColor.white.cgColor, (right ? UIColor.clear : .white).cgColor]
        fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        CATransaction.commit()
    }
}
