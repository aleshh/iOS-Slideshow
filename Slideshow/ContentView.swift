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

    private let swipeThreshold: CGFloat = 50

    var body: some View {
        content
            .onAppear {
            viewModel.refreshAuthorization()
            if viewModel.isAuthorized {
                viewModel.loadAlbums()
            }
        }
            .onChange(of: scenePhase) { _, phase in
                viewModel.setActive(phase == .active)
            }
            .onChange(of: viewModel.authorizationStatus) { _, status in
                if status == .authorized || status == .limited {
                    viewModel.loadAlbums()
                }
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
        ZStack {
            Color.black

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            if showControls {
                Button {
                    showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(.top, 12)
                .padding(.trailing, 12)
            }
        }
        .highPriorityGesture(
            TapGesture(count: 2)
                .onEnded {
                    isAspectFill.toggle()
                    showControls = true
                }
        )
        .onTapGesture {
            showControls.toggle()
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard abs(value.translation.width) > swipeThreshold,
                          abs(value.translation.width) > abs(value.translation.height) else {
                        return
                    }
                    if value.translation.width < 0 {
                        viewModel.showNext()
                    } else {
                        viewModel.showPrevious()
                    }
                }
        )
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
