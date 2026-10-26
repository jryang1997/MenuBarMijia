import Foundation

extension HomeStore {
    private static let lastUpdateCheckTimestampKey = "last_update_check_timestamp"

    private var lastUpdateCheckDate: Date? {
        get {
            guard userDefaults.object(forKey: Self.lastUpdateCheckTimestampKey) != nil else { return nil }
            let interval = userDefaults.double(forKey: Self.lastUpdateCheckTimestampKey)
            return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
        }
        set {
            if let newValue {
                userDefaults.set(newValue.timeIntervalSince1970, forKey: Self.lastUpdateCheckTimestampKey)
            } else {
                userDefaults.removeObject(forKey: Self.lastUpdateCheckTimestampKey)
            }
        }
    }

    public func checkForUpdatesIfNeeded(now: Date = Date()) async {
        guard automaticallyChecksForUpdates else { return }
        switch updateState {
        case .idle, .upToDate:
            break
        default:
            return
        }
        if let lastCheck = lastUpdateCheckDate,
           now.timeIntervalSince(lastCheck) < Self.automaticUpdateCheckInterval {
            return
        }
        await performUpdateCheck(userInitiated: false, now: now)
    }

    public func checkForUpdates(now: Date = Date()) async {
        await performUpdateCheck(userInitiated: true, now: now)
    }

    private func performUpdateCheck(userInitiated: Bool, now: Date) async {
        switch updateState {
        case .checking, .downloading, .verifying, .installing:
            return
        case .readyToRelaunch(let staged):
            if !userInitiated { return }
            updater.cleanupStagedApp(staged)
        case .idle, .upToDate, .available, .failed:
            break
        }

        updateState = .checking
        do {
            let release = try await updater.checkLatestRelease()
            guard case .checking = updateState else { return }
            lastUpdateCheckDate = now
            if let release {
                updateState = .available(release)
            } else {
                updateState = .upToDate(checkedAt: now)
            }
        } catch is CancellationError {
            if case .checking = updateState {
                updateState = .idle
            }
        } catch {
            guard case .checking = updateState else { return }
            if userInitiated {
                updateState = .failed(
                    AppUpdateFailure(
                        release: nil,
                        message: error.localizedDescription,
                        canRetryInstall: false
                    )
                )
            } else {
                updateState = .idle
            }
        }
    }

    public func startUpdateInstallation() async {
        let release: AppRelease
        switch updateState {
        case .available(let availableRelease):
            release = availableRelease
        case .failed(let failure):
            guard let failedRelease = failure.release else { return }
            release = failedRelease
        default:
            return
        }

        updateTask?.cancel()
        let attemptID = UUID()
        activeUpdateAttemptID = attemptID
        let initialTotal = release.packageAsset.flatMap { $0.sizeBytes > 0 ? $0.sizeBytes : nil }
        updateState = .downloading(release, progress: DownloadProgress(receivedBytes: 0, totalBytes: initialTotal))

        let currentUpdater = updater
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let staged = try await currentUpdater.stageUpdate(for: release) { [weak self] phase in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeUpdateAttemptID == attemptID else { return }
                        if case .verifying = self.updateState, case .downloading = phase {
                            return
                        }
                        self.updateState = phase
                    }
                }
                guard self.activeUpdateAttemptID == attemptID else {
                    currentUpdater.cleanupStagedApp(staged)
                    return
                }
                self.activeUpdateAttemptID = nil
                if Task.isCancelled {
                    currentUpdater.cleanupStagedApp(staged)
                    self.updateState = .available(release)
                } else {
                    self.updateState = .readyToRelaunch(staged)
                }
            } catch is CancellationError {
                guard self.activeUpdateAttemptID == attemptID else { return }
                self.activeUpdateAttemptID = nil
                self.updateState = .available(release)
            } catch {
                guard self.activeUpdateAttemptID == attemptID else { return }
                self.activeUpdateAttemptID = nil
                if Task.isCancelled {
                    self.updateState = .available(release)
                } else {
                    self.updateState = .failed(
                        AppUpdateFailure(
                            release: release,
                            message: error.localizedDescription,
                            canRetryInstall: release.packageAsset != nil
                        )
                    )
                }
            }
        }
        updateTask = task
        await task.value
    }

    public func cancelUpdateInstallation() {
        activeUpdateAttemptID = nil
        updateTask?.cancel()
        updateTask = nil
        if case .readyToRelaunch(let staged) = updateState {
            updater.cleanupStagedApp(staged)
        }
        if let release = updateState.associatedRelease {
            updateState = .available(release)
        }
    }

    public func confirmRelaunchForUpdate() {
        guard case .readyToRelaunch(let staged) = updateState else { return }
        updateState = .installing(staged.release)
        KeychainHelper.synchronizeFallbackCredentialsBeforeUpdate(defaults: userDefaults)
        do {
            try updater.installStagedUpdateAndRelaunch(staged)
            onTerminateForUpdate?()
        } catch {
            updater.cleanupStagedApp(staged)
            updateState = .failed(
                AppUpdateFailure(
                    release: staged.release,
                    message: error.localizedDescription,
                    canRetryInstall: true
                )
            )
        }
    }
}
