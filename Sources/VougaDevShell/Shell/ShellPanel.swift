import UIKit

/// The shell's native screens over the web view, in the app's brand: the sign-in (the app's mark, its name in its own
/// type, one sentence, one button), the notifications question, the offline screen (an offline icon, a title, a sentence,
/// Try again). Dynamic Type, the safe area and the app's colours; the button keeps rounded-rectangle corners, never a
/// circle, and is at least 56 points high, as on the other platform.
final class ShellPanel: UIView {

    private let image = UIImageView()
    private let title = UILabel()
    private let text = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let button = UIButton(configuration: .filled())
    private let link = UIButton(configuration: .plain())
    /// The pages kept on the phone, offered when the one asked for is not.
    private let rows = UIStackView()
    private let colors: ShellColors
    private let stack: UIStackView
    private var imageSize: NSLayoutConstraint!
    private let brandTitle: UIFont
    private let plainTitle = UIFont.preferredFont(forTextStyle: .title2).withWeight(.semibold)
    var onButton: (() -> Void)?
    var onLink: (() -> Void)?

    init(colors: ShellColors, titleFont: UIFont?) {
        brandTitle = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: titleFont ?? .systemFont(ofSize: 34, weight: .bold))
        stack = UIStackView(arrangedSubviews: [image, title, text, rows, spinner, button, link])
        self.colors = colors
        super.init(frame: .zero)
        rows.axis = .vertical
        rows.spacing = 8
        backgroundColor = colors.background

        image.contentMode = .scaleAspectFit
        image.tintColor = colors.accent
        image.isAccessibilityElement = false
        imageSize = image.heightAnchor.constraint(equalToConstant: 144)
        NSLayoutConstraint.activate([imageSize, image.widthAnchor.constraint(equalTo: image.heightAnchor)])

        title.adjustsFontForContentSizeCategory = true
        title.textColor = colors.text
        title.numberOfLines = 0
        title.lineBreakMode = .byWordWrapping
        title.textAlignment = .center
        // A title wraps onto the lines it needs, never cut: it may not be squeezed vertically.
        title.setContentCompressionResistancePriority(.required, for: .vertical)
        text.setContentCompressionResistancePriority(.required, for: .vertical)
        title.accessibilityTraits = .header
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.textColor = colors.muted
        text.numberOfLines = 0
        text.textAlignment = .center
        spinner.color = colors.accent

        var look = UIButton.Configuration.filled()
        look.baseBackgroundColor = colors.accent
        look.baseForegroundColor = colors.onAccent
        look.cornerStyle = .fixed
        look.background.cornerRadius = 12
        look.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 28, bottom: 14, trailing: 28)
        look.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
            return attributes
        }
        button.configuration = look
        button.addAction(UIAction { [weak self] _ in self?.onButton?() }, for: .primaryActionTriggered)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        var quiet = UIButton.Configuration.plain()
        quiet.baseForegroundColor = colors.muted
        link.configuration = quiet
        link.addAction(UIAction { [weak self] _ in self?.onLink?() }, for: .primaryActionTriggered)
        link.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        // What UI tests find the panel by, in any language.
        title.accessibilityIdentifier = "shell.panel.title"
        text.accessibilityIdentifier = "shell.panel.text"
        button.accessibilityIdentifier = "shell.panel.button"
        link.accessibilityIdentifier = "shell.panel.link"

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 0
        stack.setCustomSpacing(16, after: image)
        stack.setCustomSpacing(12, after: title)
        stack.setCustomSpacing(32, after: text)
        stack.setCustomSpacing(32, after: rows)
        stack.setCustomSpacing(32, after: spinner)
        stack.setCustomSpacing(16, after: button)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let guide = safeAreaLayoutGuide
        // The width of the screen less its margins, at most 480 points (an iPad): the texts wrap instead of being cut.
        let wide = stack.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -64)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            stack.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 24),
            wide,
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            text.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor),
            button.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Built in code") }

    /// [image] heads the screen ([brand]: the app's mark over its name in its own type; else an icon over a plain title).
    /// [button] nil shows the spinner instead: work under way. [link] is the quiet line under the button.
    /// [rows] are choices listed under the sentence (a kept page: its title, and what a tap does). [busy] shows the spinner;
    /// by default when there is no button.
    func show(title: String, text: String, button: String?, link: String? = nil, image: UIImage? = nil, brand: Bool = false,
              rows: [(String, () -> Void)] = [], busy: Bool? = nil) {
        self.rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (label, action) in rows {
            var look = UIButton.Configuration.gray()
            look.title = label
            look.baseForegroundColor = colors.text
            look.cornerStyle = .fixed
            look.background.cornerRadius = 12
            look.titleLineBreakMode = .byTruncatingTail
            look.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
            let row = UIButton(configuration: look, primaryAction: UIAction { _ in action() })
            row.contentHorizontalAlignment = .leading
            row.accessibilityIdentifier = "shell.panel.row"
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            self.rows.addArrangedSubview(row)
        }
        self.rows.isHidden = rows.isEmpty
        self.image.image = image
        self.image.isHidden = image == nil
        imageSize.constant = brand ? 144 : 64
        self.title.font = brand ? brandTitle : plainTitle
        self.title.text = title
        self.title.invalidateIntrinsicContentSize()
        self.text.text = text
        self.button.isHidden = button == nil
        self.button.configuration?.title = button
        self.link.isHidden = link == nil
        self.link.configuration?.title = link
        let spinning = busy ?? (button == nil)
        if spinning { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.isHidden = !spinning
        isHidden = false
        UIAccessibility.post(notification: .screenChanged, argument: self.text)
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont(descriptor: fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]]), size: 0)
    }
}
