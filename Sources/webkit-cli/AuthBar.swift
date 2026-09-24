import AppKit
import WebKit

/// The strip shown over a page a person has to act on: what to do, where the page is, and Done.
@MainActor
final class AuthBar: NSView {
  private let urlLabel = NSTextField(labelWithString: "")
  private let instructionLabel: NSTextField
  private var urlObservation: NSKeyValueObservation?

  init(web: WKWebView, instruction: String, onDone: @escaping () -> Void) {
    instructionLabel = NSTextField(labelWithString: instruction)
    super.init(frame: NSRect(x: 0, y: 0, width: viewport.width, height: 44))

    instructionLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    instructionLabel.lineBreakMode = .byTruncatingTail
    instructionLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

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

    let stack = NSStackView(views: [instructionLabel, urlLabel, spacer, done])
    stack.orientation = .horizontal
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      heightAnchor.constraint(equalToConstant: 44),
    ])

    urlObservation = web.observe(\.url, options: [.initial, .new]) { [weak self] web, _ in
      MainActor.assumeIsolated { self?.urlLabel.stringValue = web.url?.absoluteString ?? "" }
    }
  }

  var instruction: String {
    get { instructionLabel.stringValue }
    set { instructionLabel.stringValue = newValue }
  }

  required init?(coder: NSCoder) { fatalError("not used") }
}

/// The auth window's content: the bar above the page.
@MainActor
final class AuthContainer: NSView {
  init(web: WKWebView, onDone: @escaping () -> Void) {
    super.init(frame: NSRect(origin: .zero, size: NSSize(width: viewport.width, height: viewport.height + 44)))
    let bar = AuthBar(web: web, instruction: "Sign in, then click Done.", onDone: onDone)
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
