import SwiftUI

struct ConnectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var editing: SyncConnection? = nil

    @State private var name = ""
    @State private var remotePath = ""
    @State private var localPath = ""

    private var isEditing: Bool { editing != nil }

    private var canSubmit: Bool {
        !remotePath.isEmpty && !localPath.isEmpty && !model.isBusy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Work Server"))
                }

                Section {
                    HStack {
                        TextField("Path", text: $remotePath, prompt: Text("/Volumes/Share"))
                        Button("Browse…") {
                            if let path = AppModel.pickFolder(title: "Choose a network volume or folder") {
                                remotePath = path
                                if name.isEmpty {
                                    name = URL(fileURLWithPath: path).lastPathComponent
                                }
                            }
                        }
                    }
                } header: {
                    Text("Network Volume")
                } footer: {
                    Text("A mounted SMB, AFP, or NFS volume.")
                }

                Section {
                    HStack {
                        TextField("Path", text: $localPath, prompt: Text("Sync Folder"))
                        Button("Browse…") {
                            if let path = AppModel.pickFolder(title: "Choose a local folder") {
                                localPath = path
                            }
                        }
                    }
                } header: {
                    Text("Local Folder")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isEditing
                             ? "Selected files and folders will be downloaded here."
                             : "Existing local files will be uploaded and kept on this Mac. Conflicting versions are kept under different names; online-only files are not downloaded.")
                        if model.isBusy {
                            Text(model.statusMessage)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let error = model.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Connection" : "Connect Volume")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitLabel) {
                        Task {
                            if let conn = editing {
                                await model.updateConnection(
                                    id: conn.id,
                                    name: name,
                                    remotePath: remotePath,
                                    localPath: localPath
                                )
                            } else {
                                await model.connectNew(
                                    name: name,
                                    remotePath: remotePath,
                                    localPath: localPath
                                )
                            }
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .frame(width: 460, height: 360)
        .onAppear {
            if let conn = editing {
                name = conn.name
                remotePath = conn.remotePath
                localPath = conn.localPath
            }
        }
    }

    private var submitLabel: String {
        if model.isBusy { return isEditing ? "Saving…" : "Connecting…" }
        return isEditing ? "Save" : "Connect"
    }
}
