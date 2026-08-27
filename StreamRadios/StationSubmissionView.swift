import SwiftUI
import MessageUI

// MARK: - Submission Role Enum
enum SubmissionRole: String, CaseIterable {
    case owner = "Official Content Creator"
    case contributor = "Community Member"
    
    var description: String {
        switch self {
        case .owner:
            return "I am the creator, owner, or authorized representative of this radio station or podcast"
        case .contributor:
            return "I am a fan or community member recommending this content to be added to the platform"
        }
    }
}

// MARK: - Content Submission Data Model
struct ContentSubmissionData {
    var role: SubmissionRole = .contributor
    var email: String = ""
    var fullName: String = ""
    var phoneNumber: String = ""
    var company: String = ""
    var jobTitle: String = ""
    var contentName: String = ""
    var website: String = ""
    var contentURL: String = ""
    var agreedToTerms: Bool = false
    
    // Validation errors
    var emailError: String? = nil
    var fullNameError: String? = nil
    var phoneNumberError: String? = nil
    var companyError: String? = nil
    var jobTitleError: String? = nil
    var contentNameError: String? = nil
    var websiteError: String? = nil
    var contentURLError: String? = nil
    var termsError: String? = nil
    
    mutating func validateAllFields() -> Bool {
        var isValid = true
        
        // Clear previous errors
        clearErrors()
        
        // Email validation
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emailError = "Email is required"
            isValid = false
        } else if !isValidEmail(email) {
            emailError = "Please enter a valid email address"
            isValid = false
        }
        
        // Full name validation
        if fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fullNameError = "Full name is required"
            isValid = false
        }
        
        // Phone number validation
        if phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            phoneNumberError = "Phone number is required"
            isValid = false
        }
        
        // Company validation (only for owner role)
        if role == .owner && company.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            companyError = "Company is required"
            isValid = false
        }
        
        // Job title validation (only for owner role)
        if role == .owner && jobTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            jobTitleError = "Job title is required"
            isValid = false
        }
        
        // Content name validation
        if contentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contentNameError = "Content name is required"
            isValid = false
        }
        
        // Website validation
        if website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            websiteError = "Website is required"
            isValid = false
        } else if !isValidURL(website) {
            websiteError = "Please enter a valid website URL"
            isValid = false
        }
        
        // Content URL validation
        if contentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contentURLError = "Content URL is required"
            isValid = false
        } else if !isValidURL(contentURL) {
            contentURLError = "Please enter a valid content URL"
            isValid = false
        }
        
        // Terms agreement validation
        if !agreedToTerms {
            termsError = "You must agree to the Terms of Use"
            isValid = false
        }
        
        return isValid
    }
    
    private mutating func clearErrors() {
        emailError = nil
        fullNameError = nil
        phoneNumberError = nil
        companyError = nil
        jobTitleError = nil
        contentNameError = nil
        websiteError = nil
        contentURLError = nil
        termsError = nil
    }
    
    func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
    
    func isValidURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return url.scheme != nil && url.host != nil
    }
}

// MARK: - Main Content Submission View
struct ContentSubmissionView: View {
    // Scroll detection bindings for TabView hide functionality
    @Binding var isScrolling: Bool
    @Binding var isFooterMenuHidden: Bool
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var showingRoleSelection = true
    @State private var showingForm = false
    @State private var submissionData = ContentSubmissionData()
    @State private var showingTerms = false
    @State private var hasOpenedTerms = false
    @State private var showTermsAlert = false
    @State private var isSubmitting = false
    @State private var showingMailComposer = false
    @State private var mailComposerError: String? = nil
    @State private var showingSuccessScreen = false
    
    // Default initializer for backward compatibility
    init() {
        self._isScrolling = .constant(false)
        self._isFooterMenuHidden = .constant(false)
    }
    
    // Main initializer with scroll detection bindings
    init(isScrolling: Binding<Bool>, isFooterMenuHidden: Binding<Bool>) {
        self._isScrolling = isScrolling
        self._isFooterMenuHidden = isFooterMenuHidden
    }
    
    private var backgroundColor: some View {
        colorScheme == .dark ? 
            AnyView(LinearGradient(colors: [Color(.systemGray6).opacity(0.8), Color.black], startPoint: .top, endPoint: .bottom)) :
            AnyView(LinearGradient(colors: [Color(.systemBackground), Color(.systemGroupedBackground)], startPoint: .top, endPoint: .bottom))
    }
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color(.systemGray6).opacity(0.3) : .white
    }
    
    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .primary
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color(.systemGray) : .secondary
    }
    
    private var accentGradient: LinearGradient {
        LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
    }
    
    private var shadowColor: Color {
        colorScheme == .dark ? .clear : .black.opacity(0.1)
    }
    
    var body: some View {
        Group {
                if showingSuccessScreen {
                    successScreen
                } else if showingRoleSelection {
                    roleSelectionView
                } else {
                    submissionFormView
                }
            }
            .background(backgroundColor)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                
                ToolbarItem(placement: .principal) {
                    Text("Content Submission")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(primaryTextColor)
                }
            }
        .sheet(isPresented: $showingTerms) {
            TermsAndConditionsView(showDragIndicator: true)
        }
        .alert("Terms of Use Required", isPresented: $showTermsAlert) {
            Button("Read Terms of Use") {
                showingTerms = true
                hasOpenedTerms = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Please read the Terms of Use before submitting your station for approval.")
        }
        .sheet(isPresented: $showingMailComposer) {
            if MFMailComposeViewController.canSendMail() {
                MailComposeView(
                    submissionData: submissionData,
                    isPresented: $showingMailComposer,
                    completion: { result in
                        handleMailResult(result)
                    }
                )
            }
        }
        .alert("Email Error", isPresented: .constant(mailComposerError != nil)) {
            Button("OK") {
                mailComposerError = nil
            }
        } message: {
            Text(mailComposerError ?? "")
        }
    }
    
    // MARK: - Role Selection View
    private var roleSelectionView: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header instruction with modern styling
                VStack(spacing: 16) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 50))
                        .foregroundStyle(accentGradient)
                        .padding(.top, 20)
                    
                    Text("Choose your submission type to get started")
                        .font(.title2)
                        .fontWeight(.medium)
                        .foregroundColor(primaryTextColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                // Role options with enhanced cards
                VStack(spacing: 20) {
                    ForEach(SubmissionRole.allCases, id: \.self) { role in
                        roleOptionCard(role: role)
                    }
                }
                .padding(.horizontal, 20)
                
                // Continue button with gradient
                Button("Continue") {
                    proceedToForm()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(AnyView(accentGradient))
                .foregroundColor(.white)
                .font(.headline)
                .cornerRadius(16)
                .shadow(color: shadowColor, radius: 8, x: 0, y: 4)
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            .padding(.vertical, 20)
            .safeAreaInset(edge: .bottom) {
                // Add space at bottom to prevent player obstruction
                Color.clear.frame(height: 100)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 10) // Set minimum distance to 10 to avoid interfering with button taps
                .onChanged { _ in
                    // IMMEDIATE update - no conditions, just set it
                    DispatchQueue.main.async {
                        if !isScrolling {
                            print("🏠 DEBUG: Setting isScrolling = true in ContentSubmissionView (roleSelectionView)")
                            isScrolling = true
                            // REMOVED: isFooterMenuHidden = true - let ContentView shouldHideFooterMenu logic handle this
                        }
                    }
                }
                .onEnded { _ in
                    // Debounce the scroll end to prevent rapid state changes
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        print("🏠 DEBUG: Setting isScrolling = false in ContentSubmissionView (roleSelectionView)")
                        isScrolling = false
                        // Note: Don't reset isFooterMenuHidden here - let home button control it
                    }
                }
        )
    }
    
    private func roleOptionCard(role: SubmissionRole) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                submissionData.role = role
            }
        } label: {
            HStack(spacing: 16) {
                // Selection indicator with gradient
                ZStack {
                    Circle()
                        .fill(submissionData.role == role ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.gray.opacity(0.3)))
                        .frame(width: 24, height: 24)
                    
                    if submissionData.role == role {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text(role.rawValue)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(primaryTextColor)
                        .multilineTextAlignment(.leading)
                    
                    Text(role.description)
                        .font(.subheadline)
                        .foregroundColor(secondaryTextColor)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                }
                
                Spacer()
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(cardBackgroundColor)
                    .shadow(color: shadowColor, radius: submissionData.role == role ? 12 : 4, x: 0, y: submissionData.role == role ? 6 : 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(submissionData.role == role ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.clear), lineWidth: 2)
            )
            .scaleEffect(submissionData.role == role ? 1.02 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.easeInOut(duration: 0.2), value: submissionData.role)
    }
    
    private func proceedToForm() {
        withAnimation(.easeInOut(duration: 0.3)) {
            showingRoleSelection = false
            showingForm = true
        }
    }
    
    // MARK: - Submission Form View
    private var submissionFormView: some View {
        VStack(spacing: 0) {
            // Role header
            HStack {
                Text(submissionData.role.rawValue)
                    .font(.headline)
                    .foregroundColor(primaryTextColor)
                Spacer()
            }
            .padding()
            .background(cardBackgroundColor)
            
            // Form content
            ScrollView {
                VStack(spacing: 20) {

                    
                    // Form fields based on role
                    formFields
                    
                    // Terms agreement
                    termsAgreementSection
                    
                    // Submit button integrated into form
                    Button {
                        submitForm()
                    } label: {
                        HStack(spacing: 12) {
                            if isSubmitting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            }
                            Text(isSubmitting ? "Submitting..." : "Submit")
                                .font(.headline)
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(canSubmit ? AnyView(accentGradient) : AnyView(Color.gray.opacity(0.5)))
                        .foregroundColor(.white)
                        .cornerRadius(16)
                        .shadow(color: canSubmit ? shadowColor : Color.clear, radius: 8, x: 0, y: 4)
                    }
                    .disabled(!canSubmit || isSubmitting)
                    .animation(.easeInOut(duration: 0.2), value: canSubmit)
                    .padding(.top, 20)
                    
                    Spacer(minLength: 50)
                }
                .padding()
                .safeAreaInset(edge: .bottom) {
                    // Add extra space at bottom to prevent player obstruction
                    Color.clear.frame(height: 120)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 10) // Set minimum distance to 10 to avoid interfering with button taps
                    .onChanged { _ in
                        // IMMEDIATE update - no conditions, just set it
                        DispatchQueue.main.async {
                            if !isScrolling {
                                print("🏠 DEBUG: Setting isScrolling = true in ContentSubmissionView (submissionFormView)")
                                isScrolling = true
                                // REMOVED: isFooterMenuHidden = true - let ContentView shouldHideFooterMenu logic handle this
                            }
                        }
                    }
                    .onEnded { _ in
                        // Debounce the scroll end to prevent rapid state changes
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            print("🏠 DEBUG: Setting isScrolling = false in ContentSubmissionView (submissionFormView)")
                            isScrolling = false
                            // Note: Don't reset isFooterMenuHidden here - let home button control it
                        }
                    }
            )
        }
        .background(backgroundColor)
    }
    
    // MARK: - Form Fields
    private var formFields: some View {
        VStack(spacing: 20) {
            // Email
            FormTextField(
                title: "Email",
                text: $submissionData.email,
                error: submissionData.emailError,
                placeholder: "Enter your email address",
                keyboardType: .emailAddress
            )
            .onChange(of: submissionData.email) { _, _ in
                validateEmailField()
            }
            
            // Full name
            FormTextField(
                title: "Full name",
                text: $submissionData.fullName,
                error: submissionData.fullNameError,
                placeholder: "Enter your full name",
                capitalization: .words
            )
            
            // Phone number
            FormTextField(
                title: "Phone number",
                text: $submissionData.phoneNumber,
                error: submissionData.phoneNumberError,
                placeholder: "Enter your phone number",
                keyboardType: .numberPad
            )
            
            // Company (only for owner role)
            if submissionData.role == .owner {
                FormTextField(
                    title: "Company",
                    text: $submissionData.company,
                    error: submissionData.companyError,
                    placeholder: "Enter your company name"
                )
                
                // Job Title (only for owner role)
                FormTextField(
                    title: "Job Title",
                    text: $submissionData.jobTitle,
                    error: submissionData.jobTitleError,
                    placeholder: "Enter your job title"
                )
            }
            
            // Content Name
            FormTextField(
                title: "Radio Station / Podcast Name",
                text: $submissionData.contentName,
                error: submissionData.contentNameError,
                placeholder: "Enter radio station or podcast name",
                capitalization: .words
            )
            
            // Website
            FormTextField(
                title: "Website",
                text: $submissionData.website,
                error: submissionData.websiteError,
                placeholder: "Enter website URL",
                keyboardType: .URL
            )
            .onChange(of: submissionData.website) { _, _ in
                validateWebsiteField()
            }
            
            // Content URL
            FormTextField(
                title: "Stream / Podcast RSS URL",
                text: $submissionData.contentURL,
                error: submissionData.contentURLError,
                placeholder: "Enter stream URL or podcast RSS feed URL",
                keyboardType: .URL
            )
            .onChange(of: submissionData.contentURL) { _, _ in
                validateContentURLField()
            }
        }
    }
    
    // MARK: - Terms Agreement Section
    private var termsAgreementSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    submissionData.agreedToTerms.toggle()
                } label: {
                    Image(systemName: submissionData.agreedToTerms ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundColor(submissionData.agreedToTerms ? .blue : .gray)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("I agree to the ")
                            .font(.body)
                            .foregroundColor(primaryTextColor)
                        
                        Button("Terms of Use") {
                            showingTerms = true
                            hasOpenedTerms = true
                        }
                        
                        .underline()
                        
                        Text(".")
                            .font(.body)
                            .foregroundColor(primaryTextColor)
                    }
                    
                    if let error = submissionData.termsError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                
                Spacer()
            }
        }
    }
    
    // MARK: - Computed Properties
    private var canSubmit: Bool {
        // Check if all required fields are filled
        let fieldsComplete = submissionData.agreedToTerms &&
               !submissionData.email.isEmpty &&
               !submissionData.fullName.isEmpty &&
               !submissionData.phoneNumber.isEmpty &&
               !submissionData.contentName.isEmpty &&
               !submissionData.website.isEmpty &&
               !submissionData.contentURL.isEmpty &&
               (submissionData.role == .contributor || (!submissionData.company.isEmpty && !submissionData.jobTitle.isEmpty))
        
        // Check if there are no validation errors
        let noValidationErrors = submissionData.emailError == nil &&
                                submissionData.fullNameError == nil &&
                                submissionData.phoneNumberError == nil &&
                                submissionData.contentNameError == nil &&
                                submissionData.websiteError == nil &&
                                submissionData.contentURLError == nil &&
                                submissionData.termsError == nil &&
                                (submissionData.role == .contributor || 
                                 (submissionData.companyError == nil && submissionData.jobTitleError == nil))
        
        return fieldsComplete && noValidationErrors
    }
    
    // MARK: - Real-time Validation
    private func validateEmailField() {
        let email = submissionData.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if email.isEmpty {
            submissionData.emailError = nil // Don't show error for empty field while typing
        } else if !submissionData.isValidEmail(email) {
            submissionData.emailError = "Please enter a valid email address"
        } else {
            submissionData.emailError = nil
        }
    }
    
    private func validateWebsiteField() {
        let website = submissionData.website.trimmingCharacters(in: .whitespacesAndNewlines)
        if website.isEmpty {
            submissionData.websiteError = nil // Don't show error for empty field while typing
        } else if !submissionData.isValidURL(website) {
            submissionData.websiteError = "Please enter a valid website URL"
        } else {
            submissionData.websiteError = nil
        }
    }
    
    private func validateContentURLField() {
        let contentURL = submissionData.contentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if contentURL.isEmpty {
            submissionData.contentURLError = nil // Don't show error for empty field while typing
        } else if !submissionData.isValidURL(contentURL) {
            submissionData.contentURLError = "Please enter a valid content URL"
        } else {
            submissionData.contentURLError = nil
        }
    }
    
    // MARK: - Actions
    private func submitForm() {
        print("🔄 Submit form called")
        
        // Check if user has opened Terms of Use
        guard hasOpenedTerms else {
            print("🔄 User has not opened Terms of Use")
            showTermsAlert = true
            return
        }
        
        // Validate all fields
        let isValid = submissionData.validateAllFields()
        print("🔄 Form validation result: \(isValid)")
        
        guard isValid else {
            print("🔄 Form validation failed")
            return
        }
        
        print("🔄 Form validation passed, starting submission")
        isSubmitting = true
        
        // Check if mail can be sent
        if MFMailComposeViewController.canSendMail() {
            print("🔄 Mail can be sent, opening composer")
            showingMailComposer = true
            // Don't set isSubmitting to false here - let it stay true until mail is handled
        } else {
            print("🔄 Mail cannot be sent")
            mailComposerError = "Mail is not configured on this device. Please set up Mail app to submit your station request."
            isSubmitting = false
        }
    }
    
    private func handleMailResult(_ result: MFMailComposeResult) {
        print("🔄 Mail result: \(result)")
        
        // Always clear the submitting state when mail composer closes
        isSubmitting = false
        
        switch result {
        case .sent:
            print("🔄 Mail sent successfully, showing success screen")
            showingSuccessScreen = true
        case .failed:
            print("🔄 Mail failed to send")
            mailComposerError = "Failed to send email. Please try again."
        case .cancelled, .saved:
            print("🔄 Mail cancelled or saved")
            break
        @unknown default:
            print("🔄 Unknown mail result")
            break
        }
    }
    
    // MARK: - Success Screen
    private var successScreen: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // Success icon
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.green)
                
                VStack(spacing: 12) {
                    Text("Submission Successful!")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(primaryTextColor)
                    
                    VStack(spacing: 8) {
                        Text("Thank you for your submission.")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                        
                        Text("Your content submission has been sent to our team for review. We will carefully evaluate your submission and add it to StreamRadios if it meets our quality standards.")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                        

                    }
                }
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            // Done button
            Button("Done") {
                dismiss()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
            .padding(.horizontal)
            .padding(.bottom, 50)
        }
        .navigationBarHidden(true)
    }
}

// MARK: - Form Text Field Component
struct FormTextField: View {
    let title: String
    @Binding var text: String
    let error: String?
    let placeholder: String
    var keyboardType: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .never
    
    @Environment(\.colorScheme) var colorScheme
    @FocusState private var isFocused: Bool
    
    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .primary
    }
    
    private var fieldBackgroundColor: Color {
        colorScheme == .dark ? Color(.systemGray6).opacity(0.2) : Color(.systemGray6)
    }
    
    private var borderColor: Color {
        if let error = error, !error.isEmpty {
            return .red
        } else if isFocused {
            return .blue
        } else {
            return Color.gray.opacity(0.3)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(primaryTextColor)
            
            HStack {
                TextField(placeholder, text: $text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(capitalization)
                    .disableAutocorrection(true)
                    .focused($isFocused)
                    .foregroundColor(primaryTextColor)
                
                // Clear button with proper spacing
                if !text.isEmpty {
                    Button(action: {
                        text = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.trailing, 4)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, text.isEmpty ? 16 : 8)
            .padding(.vertical, 16)
            .background(fieldBackgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderColor, lineWidth: isFocused ? 2 : 1)
            )
            .cornerRadius(12)
            .animation(.easeInOut(duration: 0.2), value: isFocused)
            
            if let error = error, !error.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                    
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Mail Compose View
struct MailComposeView: UIViewControllerRepresentable {
    let submissionData: ContentSubmissionData
    @Binding var isPresented: Bool
    let completion: (MFMailComposeResult) -> Void
    
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        
        // Set up email
        composer.setToRecipients(["support@streamradios.app"])
        composer.setSubject("Content Submission Request - \(submissionData.role.rawValue)")
        
        // Create email body
        let emailBody = createEmailBody()
        composer.setMessageBody(emailBody, isHTML: false)
        
        return composer
    }
    
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func createEmailBody() -> String {
        var body = """
        Station Submission Request
        
        Submission Type: \(submissionData.role.rawValue)
        
        Contact Information:
        • Email: \(submissionData.email)
        • Full Name: \(submissionData.fullName)
        • Phone Number: \(submissionData.phoneNumber)
        """
        
        if submissionData.role == .owner {
            body += """
            
            • Company: \(submissionData.company)
            • Job Title: \(submissionData.jobTitle)
            """
        }
        
        body += """
        
        Content Information:
        • Name: \(submissionData.contentName)
        • Website: \(submissionData.website)
        • URL: \(submissionData.contentURL)
        
        Terms Agreement: ✓ Agreed to Terms of Use
        
        Submitted from StreamRadios iOS App
        """
        
        return body
    }
    
    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let parent: MailComposeView
        
        init(_ parent: MailComposeView) {
            self.parent = parent
        }
        
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            parent.isPresented = false
            parent.completion(result)
        }
    }
}

#Preview {
    ContentSubmissionView()
}
