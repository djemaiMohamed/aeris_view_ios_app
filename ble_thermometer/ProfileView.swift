import SwiftUI

struct ProfileView: View {
    @State private var name: String = ""
    @State private var email: String = ""
    @State private var bio: String = ""
    @State private var profileImage: Image?
    @State private var showingImagePicker = false
    @State private var inputImage: UIImage?
    @State private var showingAlert = false

    // Key for storing data in UserDefaults
    private let profileKey = "userProfile"

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Information")) {
                    Text("Your data will be stored locally on your device.")
                        .font(.footnote)
                        .foregroundColor(.gray)
                }

                Section(header: Text("Personal Information")) {
                    TextField("Name", text: $name)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                    TextEditor(text: $bio)
                        .frame(height: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.bottom, 5)
                }

                Section(header: Text("Profile Picture")) {
                    HStack {
                        Spacer()
                        VStack {
                            if profileImage != nil {
                                profileImage?
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 100, height: 100)
                                    .clipShape(Circle())
                            } else {
                                Image(systemName: "person.circle.fill")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 100, height: 100)
                                    .foregroundColor(.gray)
                            }
                            Button("Change Picture") {
                                showingImagePicker = true
                            }
                        }
                        Spacer()
                    }
                }
            }
            .navigationTitle("Profile")
            .sheet(isPresented: $showingImagePicker, onDismiss: loadImage) {
                ImagePicker(image: $inputImage)
            }
            .onAppear {
                loadProfile()
            }
            .onDisappear {
                saveProfile()
            }
            .alert(isPresented: $showingAlert) {
                Alert(
                    title: Text("Data Storage"),
                    message: Text("Your data is stored locally on this device and will not be shared."),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    func loadImage() {
        guard let inputImage = inputImage else { return }
        profileImage = Image(uiImage: inputImage)
    }

    // Load profile data from UserDefaults
    func loadProfile() {
        if let savedProfile = UserDefaults.standard.data(forKey: profileKey),
           let decodedProfile = try? JSONDecoder().decode(UserProfile.self, from: savedProfile) {
            name = decodedProfile.name
            email = decodedProfile.email
            bio = decodedProfile.bio
            if let imageData = decodedProfile.imageData,
               let uiImage = UIImage(data: imageData) {
                profileImage = Image(uiImage: uiImage)
            }
        }
    }

    // Save profile data to UserDefaults
    func saveProfile() {
        let imageData = profileImage?.asUIImage().pngData()
        let profile = UserProfile(name: name, email: email, bio: bio, imageData: imageData)
        if let encodedProfile = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(encodedProfile, forKey: profileKey)
        }
    }
}

// Helper struct to hold profile data
struct UserProfile: Codable {
    var name: String
    var email: String
    var bio: String
    var imageData: Data?
}

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.presentationMode) var presentationMode

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {

    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let uiImage = info[.originalImage] as? UIImage {
                parent.image = uiImage
            }

            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

extension Image {
    func asUIImage() -> UIImage {
        let controller = UIHostingController(rootView: self)
        controller.view.frame = CGRect(x: 0, y: 0, width: 100, height: 100) // Set frame as needed
        controller.view.backgroundColor = .clear
        return controller.view.asImage()
    }
}

extension UIView {
    func asImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { rendererContext in
            layer.render(in: rendererContext.cgContext)
        }
    }
}
