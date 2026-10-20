import AppKit
import AVFoundation
import QuartzCore
import MacMonitorCore

final class MotionRegionEditor: NSWindowController {
    private let canvas = MotionRegionCanvas(frame: .zero)
    private let mode = NSSegmentedControl(labels: ["감지 영역 추가 (초록)", "제외 영역 추가 (빨강)"], trackingMode: .selectOne, target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var regions: MotionRegions
    private var history: [MotionRegions] = []
    private var completion: ((MotionRegions?) -> Void)?

    init(regions: MotionRegions, preview: AVCaptureVideoPreviewLayer?, completion: @escaping (MotionRegions?) -> Void) {
        self.regions = regions
        self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "움직임 감지·제외 영역"
        super.init(window: window)
        let note = NSTextField(wrappingLabelWithString: "화면 위에서 드래그해 사각형을 추가하세요. 감지 영역이 없으면 전체 화면을 검사하고 빨간 제외 영역이 우선합니다. 좌상단 기준·좌우 반전 없음. 미리보기는 현재 감시 중인 카메라입니다. 감시 중지 상태에서 열면 검은 화면이며 여기서 카메라를 켜지는 않습니다. 편집 중 감시를 멈추면 마지막 화면이 남을 수 있습니다. 영역은 감지만 제어하며 녹화 영상을 가리지 않습니다.")
        note.textColor = .secondaryLabelColor
        mode.selectedSegment = 0
        canvas.preview = preview
        canvas.onRectangle = { [weak self] rectangle in self?.add(rectangle) }
        let undo = NSButton(title: "마지막 변경 취소", target: self, action: #selector(undo))
        let clear = NSButton(title: "전체 화면으로 초기화", target: self, action: #selector(clear))
        let cancel = NSButton(title: "취소", target: self, action: #selector(cancel))
        let apply = NSButton(title: "영역 적용", target: self, action: #selector(apply))
        let buttons = NSStackView(views: [undo, clear, NSView(), cancel, apply])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [note, mode, canvas, message, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20),
            canvas.widthAnchor.constraint(equalTo: stack.widthAnchor),
            canvas.heightAnchor.constraint(equalTo: canvas.widthAnchor, multiplier: 9.0 / 16.0),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func add(_ rectangle: MotionRectangle) {
        let exclusion = mode.selectedSegment == 1
        guard (exclusion ? regions.exclusion.count : regions.detection.count) < MotionRegions.maximumRectangles else {
            message.stringValue = "감지·제외 영역은 각각 최대 12개입니다. 취소 또는 초기화 후 다시 추가하세요."; return
        }
        history.append(regions)
        if exclusion { regions.exclusion.append(rectangle) } else { regions.detection.append(rectangle) }
        refresh()
    }
    private func refresh() {
        canvas.regions = regions
        message.stringValue = "감지 \(regions.detection.count)개 · 제외 \(regions.exclusion.count)개 · 유효 감지 표본 \(regions.activeSampleCount)/2304 (720p 기준). 최소 \(MotionRegions.minimumActiveSamples)개, 가로·세로 각각 2줄 이상이 필요합니다. 적용 후 저장하고 감시를 재시작하세요."
    }
    @objc private func undo() { if let previous = history.popLast() { regions = previous; refresh() } }
    @objc private func clear() { history.append(regions); regions = MotionRegions(); refresh() }
    @objc private func cancel() { finish(nil) }
    @objc private func apply() {
        do { try regions.validate(); finish(regions) } catch { message.stringValue = error.localizedDescription }
    }
    private func finish(_ value: MotionRegions?) {
        canvas.preview?.session = nil
        let done = completion; completion = nil
        done?(value)
    }
}

private final class MotionRegionCanvas: NSView {
    var preview: AVCaptureVideoPreviewLayer? { didSet { oldValue?.removeFromSuperlayer(); if let preview { layer?.insertSublayer(preview, at: 0) }; needsLayout = true } }
    var regions = MotionRegions() { didSet { redraw() } }
    var onRectangle: ((MotionRectangle) -> Void)?
    private var anchor: NSPoint?
    private var draft: NSRect?
    private var shapes: [CAShapeLayer] = []

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }
    override func layout() { super.layout(); preview?.frame = bounds; redraw() }

    private func point(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }
    override func mouseDown(with event: NSEvent) { anchor = point(event); draft = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }; let p = point(event)
        draft = NSRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y), width: abs(p.x - anchor.x), height: abs(p.y - anchor.y)); redraw()
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        defer { anchor = nil; draft = nil; redraw() }
        guard let draft, bounds.width > 0, bounds.height > 0, draft.width / bounds.width >= 0.02, draft.height / bounds.height >= 0.02 else { return }
        onRectangle?(MotionRectangle(x: Double(draft.minX / bounds.width), y: Double(1 - draft.maxY / bounds.height), width: Double(draft.width / bounds.width), height: Double(draft.height / bounds.height)))
    }
    private func redraw() {
        shapes.forEach { $0.removeFromSuperlayer() }; shapes.removeAll()
        for (rectangles, color) in [(regions.detection, NSColor.systemGreen), (regions.exclusion, NSColor.systemRed)] {
            for r in rectangles {
                addShape(NSRect(x: CGFloat(r.x) * bounds.width, y: CGFloat(1 - r.y - r.height) * bounds.height, width: CGFloat(r.width) * bounds.width, height: CGFloat(r.height) * bounds.height), color: color)
            }
        }
        if let draft { addShape(draft, color: .white) }
    }
    private func addShape(_ rect: NSRect, color: NSColor) {
        let shape = CAShapeLayer(); shape.frame = bounds; shape.path = CGPath(rect: rect, transform: nil)
        shape.strokeColor = color.cgColor; shape.fillColor = color.withAlphaComponent(0.15).cgColor; shape.lineWidth = 2
        layer?.addSublayer(shape); shapes.append(shape)
    }
}
