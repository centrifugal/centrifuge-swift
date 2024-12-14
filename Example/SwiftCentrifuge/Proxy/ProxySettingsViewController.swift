//
//  ProxySettingsViewController.swift
//  SwiftCentrifuge
//

import UIKit

// MARK: - ProxySettingsViewController

class ProxySettingsViewController: UIViewController {
    typealias OnSaveCallback = ((_ proxy: ViewController.ProxySetting) -> Void)

    // MARK: - Callback Closure

    var onSave: OnSaveCallback?

    // MARK: - UI Elements

    private let scrollView = UIScrollView()
    private let contentView = UIView()

    private let mainStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let isProxyEnabled: Bool
    private lazy var proxyToggleStack: UIStackView = {
        let label = UILabel()
        label.text = "Enable Proxy"
        label.font = UIFont.systemFont(ofSize: 16, weight: .medium)

        let toggle = UISwitch()
        toggle.isOn = isProxyEnabled
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(proxyToggleChanged(_:)), for: .valueChanged)

        let stack = UIStackView(arrangedSubviews: [label, toggle])
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private func createFieldStack(
        field: Field,
        keyboardType: UIKeyboardType = .default,
        actions: [Selector: UIControl.Event] = .init()
    ) -> UIStackView {
        let label = UILabel()
        label.text = field.type.title
        label.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        let textField = UITextField()
        textField.placeholder = field.type.placeholder
        textField.borderStyle = .roundedRect
        textField.keyboardType = keyboardType
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.text = field.value
        textField.tag = field.type.tag

        actions.forEach { textField.addTarget(self, action: $0.key, for: $0.value) }

        let stack = UIStackView(arrangedSubviews: [label, textField])
        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        return stack
    }

    private lazy var saveButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Save Settings", for: .normal)
        button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(saveButtonTapped), for: .touchUpInside)
        return button
    }()

    // MARK: - Initializers

    init(isProxyEnabled: Bool) {
        self.isProxyEnabled = isProxyEnabled
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.isProxyEnabled = false
        super.init(coder: coder)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        setupUI()
        setupDismissKeyboardGesture()
    }
}

private extension ProxySettingsViewController {
    // MARK: - UI Setup

    func setupUI() {
        let proxyData = loadProxySettings()
        title = "Proxy Settings"

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        contentView.addSubview(mainStackView)
        mainStackView.addArrangedSubview(proxyToggleStack)

        let hostValue = proxyData.flatMap { $0.host }
        let portValue = proxyData.flatMap { String(describing: $0.port) }
        mainStackView.addArrangedSubview(createFieldStack(field: Field(type: .host, value: hostValue)))
        mainStackView.addArrangedSubview(createFieldStack(field: Field(type: .socketPort, value: portValue), keyboardType: .numberPad))
        mainStackView.addArrangedSubview(saveButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            mainStackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            mainStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            mainStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            mainStackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20)
        ])

        updateUIWith(proxyEnabled: isProxyEnabled)
    }

    // MARK: - Actions

    @objc func saveButtonTapped() {
        guard let toggle = proxyToggleStack.arrangedSubviews.compactMap({ $0 as? UISwitch }).first else {
            return
        }

        guard
            let hostTextField = view.viewWithTag(Field.FieldType.host.rawValue) as? UITextField,
            let socksPortTextField = view.viewWithTag(Field.FieldType.socketPort.rawValue) as? UITextField
        else {
            return
        }

        guard let host = hostTextField.text, !host.isEmpty else {
            showAlert(title: "Error", message: "Enter proxy server host.")
            return
        }

        guard let socksPortText = socksPortTextField.text, let socksPort = UInt16(socksPortText), isValidPort(socksPortText) else {
            showAlert(title: "Error", message: "Enter correct SOCKS port (1-65535).")
            return
        }

        guard
            let socksProxyParams = URLSessionConfiguration.ProxyParams(host: host, port: socksPort)
        else {
            showAlert(title: "Error", message: "Invalid host.")
            return
        }

        saveProxyParams(socksProxyParams)
        onSave?(toggle.isOn ? .on(socksProxyParams) : .off)
        dismiss(animated: true, completion: nil)
    }

    @objc func proxyToggleChanged(_ sender: UISwitch) {
        updateUIWith(proxyEnabled: sender.isOn)
    }

    // MARK: - Helper Methods

    func updateUIWith(proxyEnabled: Bool) {
        for subview in mainStackView.arrangedSubviews {
            if let stack = subview as? UIStackView,
               let textField = stack.arrangedSubviews.last as? UITextField {
                textField.isEnabled = proxyEnabled
                textField.alpha = proxyEnabled ? 1.0 : 0.5
            }
        }
    }

    func isValidPort(_ portString: String) -> Bool {
        if let port = UInt16(portString), port >= 1 && port <= 65535 {
            return true
        }
        return false
    }

    func showAlert(title: String, message: String) {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        present(alertController, animated: true, completion: nil)
    }

    func setupDismissKeyboardGesture() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tapGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(tapGesture)
    }

    @objc func dismissKeyboard() {
        view.endEditing(true)
    }

    func saveProxyParams(_ proxyParams: URLSessionConfiguration.ProxyParams) {
        guard let jsonData = proxyParams.jsonData else {
            return
        }

        UserDefaults.standard.set(jsonData, forKey: "WSProxySettings")
        UserDefaults.standard.synchronize()
    }

    func loadProxySettings() -> URLSessionConfiguration.ProxyParams? {
        guard
            let data = UserDefaults.standard.data(forKey: "WSProxySettings"),
            let proxy = URLSessionConfiguration.ProxyParams.create(from: data)
        else {
            return nil
        }
        return proxy
    }
}

private extension ProxySettingsViewController {
    struct Field {
        enum FieldType: Int {
            case host = 1
            case socketPort = 2

            var title: String {
                switch self {
                case .host: return "Proxy Host"
                case .socketPort: return "SOCKS Port"
                }
            }

            var placeholder: String {
                switch self {
                case .host: return "Enter proxy host"
                case .socketPort: return "Enter SOCKS port"
                }
            }

            var tag: Int { rawValue }
        }

        let type: FieldType
        let value: String?
    }
}
