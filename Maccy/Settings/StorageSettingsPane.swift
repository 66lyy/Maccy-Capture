import SwiftUI
import Defaults

struct StorageSettingsPane: View {
  @Observable
  class ViewModel {
    var saveFiles = false {
      didSet {
        Defaults.withoutPropagation {
          if saveFiles {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.files.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.files.types)
          }
        }
      }
    }

    var saveImages = false {
      didSet {
        Defaults.withoutPropagation {
          if saveImages {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.images.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.images.types)
          }
        }
      }
    }

    var saveText = false {
      didSet {
        Defaults.withoutPropagation {
          if saveText {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.text.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.text.types)
          }
        }
      }
    }

    private var observer: Defaults.Observation?

    init() {
      observer = Defaults.observe(.enabledPasteboardTypes) { change in
        self.saveFiles = change.newValue.isSuperset(of: StorageType.files.types)
        self.saveImages = change.newValue.isSuperset(of: StorageType.images.types)
        self.saveText = change.newValue.isSuperset(of: StorageType.text.types)
      }
    }

    isolated deinit {
      observer?.invalidate()
    }
  }

  @Default(.size) private var size
  @Default(.sortBy) private var sortBy

  @State private var viewModel = ViewModel()
  @State private var storageSize = Storage.shared.size

  private let sizeFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 999
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      PreferencesGroup(title: Text("Save", tableName: "StorageSettings"), symbol: "square.on.square") {
        storageToggle("Files", $viewModel.saveFiles)
        Divider()
        storageToggle("Images", $viewModel.saveImages)
        Divider()
        storageToggle("Text", $viewModel.saveText)
        Text("SaveDescription", tableName: "StorageSettings")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.bottom, 10)
      }

      PreferencesGroup(title: Text("HistorySection", tableName: "StorageSettings"), symbol: "clock") {
        PreferencesRow(title: Text("Size", tableName: "StorageSettings")) {
          HStack {
            Text(storageSize)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .help(Text("CurrentSizeTooltip", tableName: "StorageSettings"))
              .onAppear { storageSize = Storage.shared.size }
            TextField("", value: $size, formatter: sizeFormatter)
              .frame(width: 74)
              .help(Text("SizeTooltip", tableName: "StorageSettings"))
              .accessibilityLabel(Text("Size", tableName: "StorageSettings"))
            Stepper("", value: $size, in: 1...999)
              .labelsHidden()
              .accessibilityLabel(Text("Size", tableName: "StorageSettings"))
          }
        }
        Divider()

        PreferencesRow(title: Text("SortBy", tableName: "StorageSettings")) {
          Picker("", selection: $sortBy) {
            ForEach(Sorter.By.allCases) { mode in
              Text(mode.description)
            }
          }
          .labelsHidden()
          .frame(width: 176, alignment: .trailing)
          .help(Text("SortByTooltip", tableName: "StorageSettings"))
          .accessibilityLabel(Text("SortBy", tableName: "StorageSettings"))
        }
      }
    }
  }

  private func storageToggle(_ key: LocalizedStringKey, _ binding: Binding<Bool>) -> some View {
    PreferencesRow(title: Text(key, tableName: "StorageSettings")) {
      Toggle(isOn: binding) { Text(key, tableName: "StorageSettings") }
        .toggleStyle(.switch)
        .labelsHidden()
        .accessibilityLabel(Text(key, tableName: "StorageSettings"))
    }
  }
}

#Preview {
  StorageSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
