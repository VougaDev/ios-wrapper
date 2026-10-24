import UIKit

/// The shell's native screens over the web view: the sign-in (title, sentence, one button) and the offline screen
/// (title, sentence, Try again). Dynamic Type, the safe area, and the app's colours; the button keeps the system's
/// rounded-rectangle corners, never a circle, and is at least 44 points high.
final class ShellPanel: UIView {

    private let title = UILabel()
    private let text = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let button = UIButton(configuration: .filled())
    private let link = UIButton(configuration: .plain())
    var onButton: (() -> Void)?
    var onLink: (() -> Void)?

    init(colors: ShellColors) {
        super.init(frame: .zero)
        backgroundColor = colors.background
        for (label, style, color) in [(title, UIFont.TextStyle.title2, colors.text), (text, UIFont.TextStyle.body, colors.muted)] {
            label.font = .preferredFont(forTextStyle: style)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = color
            label.numberOfLines = 0
            label.textAlignment = .center
        }
        title.accessibilityTraits = .header
        spinner.color = colors.muted
        var look = UIButton.Configuration.filled()
        look.baseBackgroundColor = colors.accent
        look.baseForegroundColor = colors.onAccent
        look.cornerStyle = .medium
        look.buttonSize = .large
        button.configuration = look
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addAction(UIAction { [weak self] _ in self?.onButton?() }, for: .primaryActionTriggered)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        var quiet = UIButton.Configuration.plain()
        quiet.baseForegroundColor = colors.muted
        link.configuration = quiet
        link.titleLabel?.adjustsFontForContentSizeCategory = true
        link.addAction(UIAction { [weak self] _ in self?.onLink?() }, for: .primaryActionTriggered)
        link.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        // What UI tests find the panel by, in any language.
        title.accessibilityIdentifier = "shell.panel.title"
        text.accessibilityIdentifier = "shell.panel.text"
        button.accessibilityIdentifier = "shell.panel.button"
        link.accessibilityIdentifier = "shell.panel.link"

        let stack = UIStackView(arrangedSubviews: [title, text, spinner, button, link])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let guide = safeAreaLayoutGuide
        // The width of the screen less its margins, at most 480 points (an iPad): a definite width, so the texts wrap
        // onto as many lines as they need instead of being cut.
        let wide = stack.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -64)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            stack.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 24),
            wide,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Built in code") }

    /// [button] nil shows the spinner instead: work under way. [link] is the quiet line under the button, or none.
    func show(title: String, text: String, button: String?, link: String? = nil) {
        self.link.isHidden = link == nil
        self.link.configuration?.title = link
        self.title.text = title
        self.text.text = text
        self.button.isHidden = button == nil
        self.button.configuration?.title = button
        if button == nil { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.isHidden = button != nil
        isHidden = false
        UIAccessibility.post(notification: .screenChanged, argument: self.text)
    }
}
