import UIKit

/// The shell's native screens over the web view: the sign-in (title, sentence, one button) and the offline screen
/// (title, sentence, Try again). Dynamic Type, the safe area, and the app's colours; the button keeps the system's
/// rounded-rectangle corners, never a circle, and is at least 44 points high.
final class ShellPanel: UIView {

    private let title = UILabel()
    private let text = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let button = UIButton(configuration: .filled())
    var onButton: (() -> Void)?

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

        let stack = UIStackView(arrangedSubviews: [title, text, spinner, button])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let guide = safeAreaLayoutGuide
        // As wide as the margins allow, up to 480 points on an iPad.
        let wide = stack.widthAnchor.constraint(equalToConstant: 480)
        wide.priority = .defaultLow
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 24),
            wide,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Built in code") }

    /// [button] nil shows the spinner instead: work under way.
    func show(title: String, text: String, button: String?) {
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
