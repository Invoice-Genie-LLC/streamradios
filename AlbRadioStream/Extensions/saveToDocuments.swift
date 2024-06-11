//
//  saveToDocuments.swift
//  AlbRadioStream
//
//  Created by Kley Sulo on 6/9/24.
//

import UIKit

extension UIImage {
    func saveToDocuments() -> URL? {
        guard let data = self.jpegData(compressionQuality: 0.8) else { return nil }
        let filename = UUID().uuidString + ".jpg"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        do {
            try data.write(to: url)
            return url
        } catch {
            print("Unable to save image to documents directory: \(error)")
            return nil
        }
    }
}
