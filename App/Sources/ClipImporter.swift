import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A clip copied into the app's temporary directory, plus how it got there (so the UI can say so).
struct ImportedClip: Sendable {
    enum Source: String, Sendable {
        case photoKitOriginal = "PhotoKit original resource (true slo-mo frame rate)"
        case transferableCopy = "PhotosPicker file copy (a slo-mo clip may arrive as a 30 fps composition)"
        case recordedInApp = "Recorded in ArcLab (true frame rate and lens field of view known)"
    }
    let url: URL
    let source: Source
}

enum ClipImportError: Error, CustomStringConvertible {
    case nothingSelected
    case noVideoResource
    case transferFailed
    var description: String {
        switch self {
        case .nothingSelected: return "no item was selected"
        case .noVideoResource: return "the selected asset has no video resource"
        case .transferFailed: return "the picker returned no movie file"
        }
    }
}

/// The generic `PhotosPicker` file representation, copied to a temp URL we own.
struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = try ClipImporter.freshTempURL(ext: received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}

enum ClipImporter {
    static func freshTempURL(ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ArcLabImport", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    /// Prefers PhotoKit's *original* video resource (`PHAssetResourceType.video`): the picker's rendered
    /// representation of a slo-mo clip is a 30 fps composition, which would make every timing metric wrong.
    /// Falls back to the picker's file copy when the library cannot be read (limited access, no identifier).
    static func importClip(from item: PhotosPickerItem) async throws -> ImportedClip {
        if let id = item.itemIdentifier {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if status == .authorized || status == .limited, let clip = try await writeOriginal(localIdentifier: id) {
                return clip
            }
        }
        guard let movie = try await item.loadTransferable(type: MovieFile.self) else {
            throw ClipImportError.transferFailed
        }
        return ImportedClip(url: movie.url, source: .transferableCopy)
    }

    /// Writes the original video resource to a temp file. Returns nil when the asset is not visible to us.
    private static func writeOriginal(localIdentifier: String) async throws -> ImportedClip? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }
        let resources = PHAssetResource.assetResources(for: asset)
        // `.video` is the original file; `.fullSizeVideo` is the edited/rendered version.
        guard let resource = resources.first(where: { $0.type == .video }) ?? resources.first(where: { $0.type == .fullSizeVideo }) else {
            throw ClipImportError.noVideoResource
        }
        let ext = (resource.originalFilename as NSString).pathExtension
        let dest = try freshTempURL(ext: ext.isEmpty ? "mov" : ext)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: dest, options: options) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        return ImportedClip(url: dest, source: .photoKitOriginal)
    }
}
