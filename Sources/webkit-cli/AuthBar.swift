import AppKit
import WebKit

/// The auth window's content: a bar with the instruction, the current URL and a Done button, above the page.
@MainActor
final class AuthContainer: NSView {
  private let urlLabel = NSTextField(labelWithString: "")
  private var urlObservation: NSKeyValueObservation?

  init(web: WKWebView, onDone: @escaping () -> Void) {
    super.init(frame: NSRect(origin: .zero, size: NSSize(width: viewport.width, height: viewport.height + 44)))

    let instruction = NSTextField(labelWithString: "Sign in, then click Done.")
    instruction.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

    urlLabel.textColor = .secondaryLabelColor
    urlLabel.lineBreakMode = .byTruncatingMiddle
    urlLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    urlLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    urlLabel.isSelectable = true

    let done = DoneButton(title: "Done", action: onDone)
    done.bezelStyle = .rounded
    done.controlSize = .large
    done.bezelColor = .controlAccentColor

    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)

    let bar = NSStackView(views: [instruction, urlLabel, spacer, done])
    bar.orientation = .horizontal
    bar.spacing = 12
    bar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
    bar.setHuggingPriority(.defaultHigh, for: .vertical)

    let separator = NSBox()
    separator.boxType = .separator

    for v in [bar, separator, web] as [NSView] {
      v.translatesAutoresizingMaskIntoConstraints = false
      addSubview(v)
    }
    NSLayoutConstraint.activate([
      bar.topAnchor.constraint(equalTo: topAnchor),
      bar.leadingAnchor.constraint(equalTo: leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: trailingAnchor),
      separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
      separator.leadingAnchor.constraint(equalTo: leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: trailingAnchor),
      web.topAnchor.constraint(equalTo: separator.bottomAnchor),
      web.leadingAnchor.constraint(equalTo: leadingAnchor),
      web.trailingAnchor.constraint(equalTo: trailingAnchor),
      web.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    urlObservation = web.observe(\.url, options: [.initial, .new]) { [weak self] web, _ in
      MainActor.assumeIsolated { self?.urlLabel.stringValue = web.url?.absoluteString ?? "" }
    }
  }

  required init?(coder: NSCoder) { fatalError("not used") }
}

private final class DoneButton: NSButton {
  private var handler: (() -> Void)?

  convenience init(title: String, action: @escaping () -> Void) {
    self.init(frame: .zero)
    self.title = title
    handler = action
    target = self
    self.action = #selector(fire)
  }

  @objc private func fire() { handler?() }
}
