//
//  ContentView.swift
//  Slideshow
//
//  Created by Alesh Houdek on 1/8/26.
//

import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = SlideshowViewModel()
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var showControls = false
    @State private var showSettingsSheet = false
    @State private var isAspectFill = false
    @GestureState private var dragTranslation: CGFloat = 0
    @State private var dragOffset: CGFloat = 0
    @State private var isTransitioning = false
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var swipeDirection: SwipeDirection?

    private let swipeThreshold: CGFloat = 50
    private let controlsHideDelay: UInt64 = 1_500_000_000
    private let swipeAnimationDuration: TimeInterval = 0.2

    private enum SwipeDirection {
        case next
        case previous
    }

    var body: some View {
        content
            .onAppear {
                viewModel.refreshAuthorization()
                if viewModel.isAuthorized {
                    viewModel.loadAlbums()
                }
            }
            .statusBar(hidden: true)
            .onChange(of: scenePhase) { _, phase in
                viewModel.setActive(phase == .active)
            }
            .onChange(of: viewModel.authorizationStatus) { _, status in
                if status == .authorized || status == .limited {
                    viewModel.loadAlbums()
                    autoShowSettingsIfNeeded()
                }
            }
            .onChange(of: viewModel.selectedAlbumID) { _, _ in
                autoShowSettingsIfNeeded()
            }
            .onDisappear {
                hideControlsTask?.cancel()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.authorizationStatus {
        case .authorized, .limited:
            slideshowView
        case .notDetermined:
            permissionPrompt
        case .restricted, .denied:
            settingsPrompt
        @unknown default:
            settingsPrompt
        }
    }

    private var slideshowView: some View {
        slideshowStage
            .sheet(isPresented: $showSettingsSheet) {
                NavigationStack {
                    settingsForm
                        .navigationTitle("Settings")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    showSettingsSheet = false
                                }
                            }
                        }
                }
            }
            .onAppear {
                autoShowSettingsIfNeeded()
            }
    }

    private var slideshowStage: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let topPadding: CGFloat = 12

            ZStack {
                Color.black
                    .ignoresSafeArea()

                slideshowContent(width: width)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if showControls {
                    HStack(spacing: 12) {
                        Button {
                            openCurrentPhotoInPhotos()
                        } label: {
                            Image(systemName: "photo")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .disabled(viewModel.currentAssetIdentifier == nil)

                        Button {
                            hideControlsTask?.cancel()
                            showControls = true
                            showSettingsSheet = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .padding(.top, topPadding)
                    .padding(.trailing, 12)
                }
            }
            .highPriorityGesture(
                TapGesture(count: 2)
                    .onEnded {
                        isAspectFill.toggle()
                        showControlsTemporarily()
                    }
            )
            .onTapGesture {
                toggleControls()
            }
            .gesture(dragGesture(width: width))
        }
    }

    private func slideshowContent(width: CGFloat) -> some View {
        let totalOffset = dragOffset + dragTranslation
        let activeDirection = swipeDirection ?? swipeDirection(for: totalOffset)
        let incomingImage = incomingImage(for: activeDirection)
        let shouldShowIncoming = incomingImage != nil && (abs(totalOffset) > 0 || isTransitioning)

        return ZStack {
            currentSlide
                .offset(x: totalOffset)

            if let activeDirection, shouldShowIncoming, let incomingImage {
                imageView(for: incomingImage)
                    .offset(x: incomingOffset(for: activeDirection, totalOffset: totalOffset, width: width))
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var currentSlide: some View {
        if viewModel.isLoadingAssets {
            ProgressView("Loading photos…")
                .tint(.white)
        } else if let image = viewModel.currentImage {
            imageView(for: image)
        } else {
            ContentUnavailableView(
                "No Photos",
                systemImage: "photo.on.rectangle",
                description: Text("Pick another album with photos.")
            )
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func imageView(for image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: isAspectFill ? .fill : .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.easeInOut(duration: 0.2), value: isAspectFill)
    }

    private func swipeDirection(for offset: CGFloat) -> SwipeDirection? {
        guard offset != 0 else { return nil }
        return offset < 0 ? .next : .previous
    }

    private func incomingImage(for direction: SwipeDirection?) -> UIImage? {
        switch direction {
        case .next:
            return viewModel.nextImage
        case .previous:
            return viewModel.previousImage
        case .none:
            return nil
        }
    }

    private func incomingOffset(for direction: SwipeDirection, totalOffset: CGFloat, width: CGFloat) -> CGFloat {
        switch direction {
        case .next:
            return totalOffset + width
        case .previous:
            return totalOffset - width
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($dragTranslation) { value, state, _ in
                guard canDrag(value: value) else { return }
                state = value.translation.width
            }
            .onChanged { value in
                guard canDrag(value: value) else { return }
                swipeDirection = value.translation.width < 0 ? .next : .previous
            }
            .onEnded { value in
                guard canDrag(value: value) else { return }
                handleDragEnd(value, width: width)
            }
    }

    private func canDrag(value: DragGesture.Value) -> Bool {
        guard !isTransitioning, viewModel.currentImage != nil, viewModel.hasMultipleAssets else { return false }
        return abs(value.translation.width) > abs(value.translation.height)
    }

    private func handleDragEnd(_ value: DragGesture.Value, width: CGFloat) {
        let translation = value.translation.width
        guard abs(translation) > swipeThreshold else {
            withAnimation(.easeOut(duration: swipeAnimationDuration)) {
                dragOffset = 0
            }
            swipeDirection = nil
            return
        }

        let direction: SwipeDirection = translation < 0 ? .next : .previous
        swipeDirection = direction
        isTransitioning = true
        dragOffset = translation

        let targetOffset: CGFloat = direction == .next ? -width : width
        withAnimation(.easeInOut(duration: swipeAnimationDuration)) {
            dragOffset = targetOffset
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + swipeAnimationDuration) {
            if direction == .next {
                viewModel.showNext()
            } else {
                viewModel.showPrevious()
            }

            dragOffset = 0
            swipeDirection = nil
            isTransitioning = false
        }
    }

    private func showControlsTemporarily() {
        hideControlsTask?.cancel()
        showControls = true
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: controlsHideDelay)
            await MainActor.run {
                showControls = false
            }
        }
    }

    private func toggleControls() {
        if showControls {
            hideControlsTask?.cancel()
            showControls = false
        } else {
            showControlsTemporarily()
        }
    }

    private func openCurrentPhotoInPhotos() {
        if let identifier = viewModel.currentAssetIdentifier?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           var components = URLComponents(string: "photos-redirect://") {
            components.queryItems = [URLQueryItem(name: "id", value: identifier)]
            if let url = components.url {
                openURL(url) { handled in
                    if !handled {
                        openPhotosApp()
                    }
                }
                return
            }
        }

        openPhotosApp()
    }

    private func openPhotosApp() {
        if let url = URL(string: "photos-redirect://") {
            openURL(url)
        }
    }

    private func autoShowSettingsIfNeeded() {
        guard viewModel.isAuthorized, viewModel.selectedAlbumID == nil else { return }
        showSettingsSheet = true
    }

    private var settingsForm: some View {
        Form {
            Section("Album") {
                if viewModel.isLoadingAlbums {
                    ProgressView("Loading albums…")
                } else if viewModel.albums.isEmpty {
                    Text("No albums available.")
                } else {
                    Picker("Album", selection: $viewModel.selectedAlbumID) {
                        ForEach(viewModel.albums) { album in
                            Text(album.title + (album.isShared ? " (Shared)" : ""))
                                .tag(Optional(album.id))
                        }
                    }
                }
            }

            Section("Interval") {
                Picker("Interval", selection: $viewModel.selectedInterval) {
                    ForEach(SlideshowInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var permissionPrompt: some View {
        ContentUnavailableView(
            "Allow Photo Access",
            systemImage: "photo.on.rectangle.angled",
            description: Text("Slideshow needs access to display albums and photos.")
        )
        .overlay(alignment: .bottom) {
            Button("Allow Access") {
                viewModel.requestAccess()
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }

    private var settingsPrompt: some View {
        ContentUnavailableView(
            "Photo Access Needed",
            systemImage: "exclamationmark.triangle",
            description: Text("Enable photo access in Settings to run the slideshow.")
        )
        .overlay(alignment: .bottom) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.bordered)
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
