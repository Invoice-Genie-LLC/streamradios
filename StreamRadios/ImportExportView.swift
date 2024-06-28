//
//  ImportExportView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/27/24.
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportExportView: View {
    @State private var stations: [RadioStation] = []
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var showErrorAlert = false
    @EnvironmentObject var viewModel: RadioStationViewModel
    
    var body: some View {
        VStack {
            Text("Import and Export Stations")
                .font(.largeTitle)
                .padding()
            
            HStack {
                Button(action: { isImporting = true }) {
                    Text("Import Stations")
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(10)
                }
                
                Button(action: { exportStations() }) {
                    Text("Export Stations")
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(10)
                }
            }
            .padding()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let selectedFile = try result.get().first else { return }
                importStations(from: selectedFile)
            } catch {
                print("Failed to import stations: \(error.localizedDescription)")
                showErrorAlert = true
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: ExportDocument(stations: viewModel.stations),
            contentType: .json,
            defaultFilename: "stations"
        ) { result in
            if case .failure(let error) = result {
                print("Failed to export stations: \(error.localizedDescription)")
                showErrorAlert = true
            }
        }
        .alert(isPresented: $showErrorAlert) {
            Alert(title: Text("Error"), message: Text("Failed to import/export stations. Please ensure the file is in the correct format."), dismissButton: .default(Text("OK")))
        }
    }
    
    private func importStations(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let importedStations = try JSONDecoder().decode([RadioStation].self, from: data)
            viewModel.stations.append(contentsOf: importedStations)
            viewModel.saveStationsToFile()
            for station in importedStations {
                viewModel.saveStationToCloud(station)
            }
            print("Successfully imported \(importedStations.count) stations.")
        } catch {
            print("Failed to import stations: \(error.localizedDescription)")
            showErrorAlert = true
        }
    }
    
    private func exportStations() {
        isExporting = true
    }
}

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var stations: [RadioStation]
    
    init(stations: [RadioStation]) {
        self.stations = stations
    }
    
    init(configuration: ReadConfiguration) throws {
        self.stations = []
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(stations)
        return FileWrapper(regularFileWithContents: data)
    }
}

struct ImportExportView_Previews: PreviewProvider {
    static var previews: some View {
        ImportExportView()
            .environmentObject(RadioStationViewModel())
    }
}
