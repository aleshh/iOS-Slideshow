//
//  SlideshowViewModel.swift
//  Slideshow
//
//  Created by Alesh Houdek on 1/8/26.
//

import Combine
import Photos
import SwiftUI
import UIKit

enum SlideshowInterval: TimeInterval, CaseIterable, Identifiable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200
    case sixHours = 21600
    case twelveHours = 43200
    case oneDay = 86400

    var id: TimeInterval { rawValue }

    var label: String {
        switch self {
        case .oneMinute:
            return "1 minute"
        case .fiveMinutes:
            return "5 minutes"
        case .fifteenMinutes:
            return "15 minutes"
        case .thirtyMinutes:
            return "30 minutes"
        case .oneHour:
            return "1 hour"
        case .twoHours:
            return "2 hours"
        case .sixHours:
            return "6 hours"
        case .twelveHours:
            return "12 hours"
        case .oneDay:
            return "1 day"
        }
    }
}

@MainActor
final class SlideshowViewModel: ObservableObject {
    struct Album: Identifiable, Hashable {
        let id: String
        let title: String
        let isShared: Bool
        let collection: PHAssetCollection

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: Album, rhs: Album) -> Bool {
            lhs.id == rhs.id
        }
    }

    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var albums: [Album] = []
    @Published var selectedAlbumID: String? {
        didSet {
            guard oldValue != selectedAlbumID else { return }
            loadAssetsForSelectedAlbum()
        }
    }
    @Published var selectedInterval: SlideshowInterval = .fiveMinutes {
        didSet {
            scheduleTimer()
        }
    }
    @Published var currentImage: UIImage?
    @Published var isLoadingAlbums = false
    @Published var isLoadingAssets = false

    private let imageManager = PHCachingImageManager()
    private var allAssets: [PHAsset] = []
    private var shuffledAssets: [PHAsset] = []
    private var currentIndex = 0
    private var slideshowTimer: Timer?
    private var imageRequestID: PHImageRequestID?
    private var isActive = true

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    func refreshAuthorization() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            Task { @MainActor in
                self?.authorizationStatus = status
                if self?.isAuthorized == true {
                    self?.loadAlbums()
                }
            }
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            scheduleTimer()
        } else {
            stopTimer()
        }
    }

    func loadAlbums() {
        guard isAuthorized else { return }
        isLoadingAlbums = true

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]

        var fetchedAlbums: [Album] = []
        let albumResults = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        albumResults.enumerateObjects { collection, _, _ in
            let title = collection.localizedTitle ?? "Untitled Album"
            let isShared = collection.assetCollectionSubtype == .albumCloudShared
            fetchedAlbums.append(Album(id: collection.localIdentifier, title: title, isShared: isShared, collection: collection))
        }

        albums = fetchedAlbums

        let previousSelection = selectedAlbumID
        if let selectedAlbumID, albums.contains(where: { $0.id == selectedAlbumID }) {
            if previousSelection == selectedAlbumID {
                loadAssetsForSelectedAlbum()
            }
        } else {
            selectedAlbumID = albums.first?.id
            if selectedAlbumID == nil {
                resetSlideshow()
            }
        }

        isLoadingAlbums = false
    }

    private func loadAssetsForSelectedAlbum() {
        guard isAuthorized, let selectedAlbumID, let album = albums.first(where: { $0.id == selectedAlbumID }) else {
            resetSlideshow()
            return
        }

        isLoadingAssets = true

        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(in: album.collection, options: fetchOptions)

        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        allAssets = assets
        shuffledAssets = assets.shuffled()
        currentIndex = 0
        isLoadingAssets = false

        if allAssets.isEmpty {
            currentImage = nil
            stopTimer()
        } else {
            showCurrentAsset()
            scheduleTimer()
        }
    }

    func showNext() {
        guard !allAssets.isEmpty else {
            currentImage = nil
            stopTimer()
            return
        }

        let nextIndex = currentIndex + 1
        if nextIndex >= shuffledAssets.count {
            shuffledAssets = allAssets.shuffled()
            currentIndex = 0
        } else {
            currentIndex = nextIndex
        }

        showCurrentAsset()
        scheduleTimer()
    }

    func showPrevious() {
        guard !allAssets.isEmpty else {
            currentImage = nil
            stopTimer()
            return
        }

        if currentIndex == 0 {
            currentIndex = max(shuffledAssets.count - 1, 0)
        } else {
            currentIndex -= 1
        }

        showCurrentAsset()
        scheduleTimer()
    }

    private func showCurrentAsset() {
        guard !shuffledAssets.isEmpty else {
            currentImage = nil
            return
        }

        let asset = shuffledAssets[currentIndex]
        requestImage(for: asset)
    }

    private func requestImage(for asset: PHAsset) {
        if let imageRequestID {
            imageManager.cancelImageRequest(imageRequestID)
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        let scale = UIScreen.main.scale
        let targetSize = CGSize(
            width: UIScreen.main.bounds.width * scale,
            height: UIScreen.main.bounds.height * scale
        )

        imageRequestID = imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { [weak self] image, _ in
            self?.currentImage = image
        }
    }

    private func scheduleTimer() {
        stopTimer()
        guard isAuthorized, isActive, !allAssets.isEmpty else { return }

        slideshowTimer = Timer.scheduledTimer(withTimeInterval: selectedInterval.rawValue, repeats: true) { [weak self] _ in
            self?.showNext()
        }
    }

    private func stopTimer() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
    }

    private func resetSlideshow() {
        allAssets = []
        shuffledAssets = []
        currentIndex = 0
        currentImage = nil
        stopTimer()
    }
}
