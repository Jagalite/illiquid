    private func rawPoint(at s: CGFloat) -> CGPoint {
        guard s != 0 else { return center }
        let steps = max(1, Int(ceil(abs(s) / 6)))
        let step = s / CGFloat(steps)
        var point = center
        for index in 0..<steps {
            let midpointS = (CGFloat(index) + 0.5) * step
            let angle = tangentAngle(at: midpointS)
            point.x += cos(angle) * step
            point.y += sin(angle) * step
        }
        return point
    }
