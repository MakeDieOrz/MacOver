//
//  DebugView.swift
//  PlayTools
//
//  Created by 许沂聪 on 2024/5/28.
//

import Foundation
import UIKit

class RingView: UIView {

    var ringColor: UIColor = .blue {
        didSet {
            shapeLayer.strokeColor = ringColor.cgColor
        }
    }

    var ringWidth: CGFloat = 10 {
        didSet {
            shapeLayer.lineWidth = ringWidth
        }
    }

    var text: String? {
        didSet {
            label.text = text
            setNeedsLayout()
        }
    }

    private let shapeLayer = CAShapeLayer()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }

    private func commonInit() {
        shapeLayer.lineWidth = ringWidth
        shapeLayer.fillColor = nil
        shapeLayer.strokeColor = ringColor.cgColor
        layer.addSublayer(shapeLayer)

        label.textAlignment = .center
        label.textColor = .black
        addSubview(label)
    }

    public func setData(position: CGPoint, description: String, phase: UITouch.Phase) {
        center = position
        text = description
        let colorMap: [UIColor] = [.green, .red, .brown, .blue, .purple, .cyan, .gray, .darkGray, .black]
        let idx = phase.rawValue
        ringColor = (idx >= 0 && idx < colorMap.count) ? colorMap[idx] : .black
    }

    override func draw(_ rect: CGRect) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = CGFloat(floatLiteral: 20)

        let startAngle = -CGFloat.pi / 2
        let endAngle = startAngle + 2 * CGFloat.pi

        let path = UIBezierPath(arcCenter: center, radius: radius,
                                startAngle: startAngle, endAngle: endAngle, clockwise: true)

        shapeLayer.path = path.cgPath
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Put label 30 pixels down the ring
        label.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 20)
        label.center = CGPoint(x: bounds.midX, y: bounds.midY + 30)
    }
}

class DebugContainer: UIView {
    static let instance = DebugContainer()
    private var refreshTimer: Timer?

    private init() {
        super.init(frame: CGRect(x: 0, y: 0, width: screen.width, height: screen.height))
        PlaySettings.tagInternalView(self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview != nil {
            startRefreshTimer()
            refreshTouches()
        } else {
            stopRefreshTimer()
        }
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.refreshTouches()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshTouches() {
        guard superview != nil else {
            stopRefreshTimer()
            return
        }
        let data = DebugModel.instance.touches
        while subviews.count < data.count {
            addSubview(RingView(frame: CGRect(x: 100, y: 100, width: 300, height: 300)))
        }
        while subviews.count > data.count {
            subviews.last?.removeFromSuperview()
        }
        for (idx, point) in data.enumerated() where idx < subviews.count {
            guard let ring = subviews[idx] as? RingView else { continue }
            let description = point.description + ": " + point.phase.name()
            ring.setData(position: point.point, description: description, phase: point.phase)
        }
    }
}

extension UITouch.Phase {
    public func name() -> String {
        let nameMap = ["Began", "Moved", "Stationary", "Ended", "Cancelled",
                       "regionEntered", "regionMoved", "regionExited"]
        let idx = self.rawValue
        return (idx >= 0 && idx < nameMap.count) ? nameMap[idx] : "Unknown"
    }
}
