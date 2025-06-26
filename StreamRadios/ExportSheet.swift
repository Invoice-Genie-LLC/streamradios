// ExportSheet.swift
// StreamRadios
//
// Created by Kley Sulo on 7/20/24.
//

import SwiftUI

struct ExportSheet: UIViewControllerRepresentable {
    let fileURL: URL
    let onDismiss: () -> Void
    
    init(fileURL: URL, onDismiss: @escaping () -> Void) {
        print("🎬 DEBUG: ExportSheet init called with fileURL: \(fileURL.path)")
        self.fileURL = fileURL
        self.onDismiss = onDismiss
    }
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        print("🏗️ DEBUG: makeUIViewController called")
        print("📁 DEBUG: Creating activity controller for file: \(fileURL.path)")
        
        let activityController = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        activityController.completionWithItemsHandler = context.coordinator.completionHandler
        
        // Configure for iPad
        if let popover = activityController.popoverPresentationController {
            popover.sourceView = UIApplication.shared.windows.first?.rootViewController?.view
            popover.sourceRect = CGRect(x: UIScreen.main.bounds.width/2, y: UIScreen.main.bounds.height/2, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        
        print("✅ DEBUG: Activity controller created successfully")
        return activityController
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        print("🔄 DEBUG: updateUIViewController called")
    }
    
    func makeCoordinator() -> Coordinator {
        print("👥 DEBUG: makeCoordinator called")
        return Coordinator(self)
    }
    
    class Coordinator: NSObject {
        let parent: ExportSheet
        
        init(_ parent: ExportSheet) {
            print("🤝 DEBUG: Coordinator init called")
            self.parent = parent
        }
        
        lazy var completionHandler: UIActivityViewController.CompletionWithItemsHandler = { [weak self] (activityType, completed, returnedItems, error) in
            print("🎯 DEBUG: Activity completion handler called")
            print("📊 DEBUG: Activity type: \(String(describing: activityType))")
            print("📊 DEBUG: Completed: \(completed)")
            
            if let error = error {
                print("❌ DEBUG: Activity error: \(error.localizedDescription)")
            } else if completed {
                print("✅ DEBUG: Activity completed successfully")
            } else {
                print("🚫 DEBUG: Activity was cancelled")
            }
            
            DispatchQueue.main.async {
                self?.parent.onDismiss()
            }
        }
    }
}
