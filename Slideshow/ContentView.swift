//
//  ContentView.swift
//  Slideshow
//
//  Created by Alesh Houdek on 1/8/26.
//

import Photos
import SwiftUI

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

    private let swipeThreshold: CGFloat = 50
    private let controlsHideDelay: UInt64 = 1_500_000_000

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
                }
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
    }

    private var slideshowStage: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let topPadding: CGFloat = 12

            ZStack {
                Color.black
                    .ignoresSafeArea()

                slideshowContent
                    .offset(x: dragOffset + dragTranslation)
                    .animation(.easeInOut(duration: 0.2), value: dragOffset)
                    .ignoresSafeArea()
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

    private var slideshowContent: some View {
        Group {
            if viewModel.isLoadingAssets {
                ProgressView("Loading photos…")
                    .tint(.white)
            } else if let image = viewModel.currentImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: isAspectFill ? .fill : .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .animation(.easeInOut(duration: 0.2), value: isAspectFill)
            } else {
                ContentUnavailableView(
                    "No Photos",
                    systemImage: "photo.on.rectangle",
                    description: Text("Pick another album with photos.")
                )
                .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($dragTranslation) { value, state, _ in
                guard canDrag(value: value) else { return }
                state = value.translation.width
            }
            .onEnded { value in
                guard canDrag(value: value) else { return }
                handleDragEnd(value, width: width)
            }
    }

    private func canDrag(value: DragGesture.Value) -> Bool {
        guard !isTransitioning, viewModel.currentImage != nil else { return false }
        return abs(value.translation.width) > abs(value.translation.height)
    }

    private func handleDragEnd(_ value: DragGesture.Value, width: CGFloat) {
        let translation = value.translation.width
        guard abs(translation) > swipeThreshold else {
            withAnimation(.easeOut(duration: 0.2)) {
                dragOffset = 0
            }
            return
        }

        let direction: CGFloat = translation < 0 ? -1 : 1
        isTransitioning = true
        dragOffset = translation

        withAnimation(.easeInOut(duration: 0.2)) {
            dragOffset = direction * width
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if direction < 0 {
                viewModel.showNext()
            } else {
                viewModel.showPrevious()
            }

            dragOffset = -direction * width
            withAnimation(.easeInOut(duration: 0.2)) {
                dragOffset = 0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isTransitioning = false
            }
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
