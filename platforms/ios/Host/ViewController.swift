import UIKit

/// 宿主 App：安装引导页。真正的键盘在扩展里（系统设置启用后全局可用）。
final class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        let title = UILabel()
        title.text = "松萝输入法"
        title.font = .systemFont(ofSize: 34, weight: .bold)

        let body = UILabel()
        body.numberOfLines = 0
        body.textAlignment = .center
        body.text = """
        启用步骤：
        1. 系统设置 → 通用 → 键盘 → 键盘
        2. 添加新键盘 → 松萝
        3. 输入时长按 🌐 选择「松萝」
        """

        let engine = UILabel()
        engine.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        engine.textColor = .secondaryLabel
        engine.text = "Rust 内核 · 本地引擎 · 无服务器"

        [title, body, engine].forEach { stack.addArrangedSubview($0) }
    }
}