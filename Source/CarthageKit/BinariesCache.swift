import Foundation
import Result
import Tentacle
import ReactiveSwift
import ReactiveTask
import XCDBLD

/// Cache for binary builds
protocol BinariesCache {

    func matchingBinary(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, resolvedDependenciesHash: String, strictMatch: Bool, platforms: Set<Platform>, swiftVersion: PinnedVersion, eventObserver: Signal<ProjectEvent, NoError>.Observer?, lockTimeout: Int?, netrc: Netrc?, binaryProject: BinaryProject?) -> SignalProducer<URLLock?, CarthageError>

}

extension BinariesCache {

    static func fileURL(for dependency: Dependency, version: PinnedVersion, configuration: String, resolvedDependenciesHash: String?, swiftVersion: PinnedVersion, binaryProject: BinaryProject? = nil) -> URL {
        // Try to parse the semantic version out of the Swift version string
        let cacheBaseURL = Constants.Dependency.assetsURL
        let swiftVersionString: String = swiftVersion.description
        let versionString = version.description
        
        let fileName: String
        if let resolvedDependenciesHash = resolvedDependenciesHash {
            fileName = "\(dependency.name)-\(resolvedDependenciesHash).framework.zip"
        } else if let binaryProject = binaryProject,
            /*
             This solves an issue when trying to install some binary dependencies. Say you have a CarthageSpec:
             ```
             {
                 "7.58.0": "https://dl.google.com/dl/cpdc/0c10c95bd100a047/Google-Mobile-Ads-SDK-7.58.0.tar.gz"
             }
             ```
             and a Cartfile:
             ```
             binary "CarthageSpecs/GoogleMobileAdsSDK.json" == 7.58.0
             ```

             Before this change, calling: `update --platform ios GoogleMobileAdsSDK ` would result in the following
             error:

             ```
             error: A shell task (/usr/bin/env unzip -uo -qq -d <destination/path> <source/path>
               End-of-central-directory signature not found.  Either this file is not
               a zipfile, or it constitutes one disk of a multi-part archive.  In the
               latter case the central directory and zipfile comment will be found on
               the last disk(s) of this archive.
             ```

             This is because before this change, the binary file in question was saved as GoogleMobileAdsSDK.framework.zip
             in ~/Library/Caches/org.carthage.CarthageKit/. Then the error is thrown when we call Archive.unzip(archive:to:).
             */
            let sourceURL = binaryProject.binaryURL(for: version, configuration: configuration, swiftVersion: swiftVersion) {
            fileName = sourceURL.lastPathComponent
        } else {
            fileName = "\(dependency.name).framework.zip"
        }
        
        return cacheBaseURL.appendingPathComponent("\(swiftVersionString)/\(dependency.name)/\(versionString)/\(configuration)/\(fileName)")
    }

    static func storeFile(at fileURL: URL, for dependency: Dependency, version: PinnedVersion, configuration: String, resolvedDependenciesHash: String?, swiftVersion: PinnedVersion, lockTimeout: Int?, deleteSource: Bool = false) -> SignalProducer<URL, CarthageError> {
        let destinationURL = AbstractBinariesCache.fileURL(for: dependency, version: version, configuration: configuration, resolvedDependenciesHash: resolvedDependenciesHash, swiftVersion: swiftVersion)
        var lock: URLLock?
        return URLLock.lockReactive(url: destinationURL, timeout: lockTimeout)
            .flatMap(.merge) { urlLock -> SignalProducer<URL, CarthageError> in
                lock = urlLock
                return deleteSource ? Files.moveFile(from: fileURL, to: urlLock.url) : Files.copyFile(from: fileURL, to: urlLock.url)
            }
            .on(terminated: {
                lock?.unlock()
            })
    }
}

class AbstractBinariesCache: BinariesCache {

    private func isFileValid(_ fileURL: URL, dependency: Dependency, platforms: Set<Platform>) -> Bool {
        guard fileURL.isExistingFile else {
            return false
        }

        var tempDir: URL?
        return FileManager.default.reactive.createTemporaryDirectory()
            .flatMap(.merge) { tempDirectoryURL -> SignalProducer<URL?, CarthageError> in
                tempDir = tempDirectoryURL

                let versionFilePath = VersionFile.versionFileRelativePath(dependencyName: dependency.name)
                let versionFileURL = URL(fileURLWithPath: versionFilePath)
                let outputURL = tempDirectoryURL.appendingPathComponent(versionFileURL.lastPathComponent)

                let task = Task(launchCommand: "unzip -p \"\(fileURL.path)\" \"\(versionFilePath)\" > \"\(outputURL.path)\"")
                return task
                    .launch()
                    .ignoreTaskData()
                    .map { _ in return outputURL }
                    .flatMapError { _ in return SignalProducer<URL?, CarthageError>(value: nil) }
            }
            .map { versionFileURL -> Bool in

                guard let existingVersionFileURL = versionFileURL else {
                    // Version file not found, means we should assume all platforms are present
                    return true
                }

                guard let versionFile = VersionFile(url: existingVersionFileURL) else {
                    // Version file not valid, rebuild
                    return false
                }

                return versionFile.containsAll(platforms: platforms)
            }
            .on(terminated: {
                tempDir?.removeIgnoringErrors()
            })
            .first()!.value ?? false
    }

    func matchingBinary(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, resolvedDependenciesHash: String, strictMatch: Bool, platforms: Set<Platform>, swiftVersion: PinnedVersion, eventObserver: Signal<ProjectEvent, NoError>.Observer?, lockTimeout: Int?, netrc: Netrc?, binaryProject: BinaryProject? = nil) -> SignalProducer<URLLock?, CarthageError> {

        let fileURL = AbstractBinariesCache.fileURL(for: dependency, version: pinnedVersion, configuration: configuration, resolvedDependenciesHash: strictMatch ? resolvedDependenciesHash : nil, swiftVersion: swiftVersion, binaryProject: binaryProject)

        return URLLock.lockReactive(url: fileURL, timeout: lockTimeout)
            .flatMap(.merge) { (urlLock: URLLock) -> SignalProducer<URLLock?, CarthageError> in
                if self.isFileValid(fileURL, dependency: dependency, platforms: platforms) {
                    return SignalProducer(value: urlLock)
                } else {
                    return self.downloadBinary(for: dependency,
                                               pinnedVersion: pinnedVersion,
                                               configuration: configuration,
                                               resolvedDependenciesHash: resolvedDependenciesHash,
                                               swiftVersion: swiftVersion,
                                               destinationURL: fileURL,
                                               netrc: netrc,
                                               eventObserver: eventObserver)
                        .then(SignalProducer<URLLock?, CarthageError> { () -> Result<URLLock?, CarthageError> in
                            if urlLock.url.isExistingFile {
                                return .success(urlLock)
                            } else {
                                urlLock.unlock()
                                return .success(nil)
                            }
                        })
                }
        }
    }

    func downloadBinary(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, resolvedDependenciesHash: String, swiftVersion: PinnedVersion, destinationURL: URL, netrc: Netrc?, eventObserver: Signal<ProjectEvent, NoError>.Observer?) -> SignalProducer<(), CarthageError> {
        preconditionFailure("Should be implemented by concrete sub class")
    }
}

final class BinaryProjectCache: AbstractBinariesCache {

    let binaryProjectDefinitions: [Dependency: BinaryProject]

    init(binaryProjectDefinitions: [Dependency: BinaryProject]) {
        self.binaryProjectDefinitions = binaryProjectDefinitions
    }

    override func downloadBinary(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, resolvedDependenciesHash: String, swiftVersion: PinnedVersion, destinationURL: URL, netrc: Netrc?, eventObserver: Signal<ProjectEvent, NoError>.Observer?) -> SignalProducer<(), CarthageError> {

        guard let binaryProject = self.binaryProjectDefinitions[dependency], let sourceURL = binaryProject.binaryURL(for: pinnedVersion, configuration: configuration, swiftVersion: swiftVersion) else {

            let error: CarthageError
            if let semanticVersion = pinnedVersion.semanticVersion {
                error = CarthageError.requiredVersionNotFound(dependency, VersionSpecifier.exactly(semanticVersion))
            } else {
                error = CarthageError.requiredVersionNotFound(dependency, VersionSpecifier.gitReference(pinnedVersion.commitish))
            }

            return SignalProducer<(), CarthageError>(error: error)
        }

        return URLSession.shared.reactive.download(with: URLRequest(url: sourceURL, netrc: netrc))
            .on(started: {
                eventObserver?.send(value: .downloadingBinaries(dependency, pinnedVersion.description))
            })
            .mapError { CarthageError.readFailed(sourceURL, $0 as NSError) }
            .flatMap(.concat) { result -> SignalProducer<URL, CarthageError> in
                let downloadURL = result.0
                let response = result.1
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    return SignalProducer(error: CarthageError.httpError(statusCode: httpResponse.statusCode))
                } else {
                    return Files.moveFile(from: downloadURL, to: destinationURL)
                }
            }
            .then(SignalProducer<(), CarthageError>.empty)
    }
}

final class GitHubBinariesCache: AbstractBinariesCache {

    let repository: Repository
    let client: Client

    init(repository: Repository, client: Client) {
        self.repository = repository
        self.client = client
    }

    override func downloadBinary(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, resolvedDependenciesHash: String, swiftVersion: PinnedVersion, destinationURL: URL, netrc: Netrc?, eventObserver: Signal<ProjectEvent, NoError>.Observer?) -> SignalProducer<(), CarthageError> {

        return GitHubBinariesCache.downloadMatchingBinary(for: dependency, pinnedVersion: pinnedVersion, configuration: configuration, swiftVersion: swiftVersion, destinationURL: destinationURL, fromRepository: self.repository, client: self.client, eventObserver: eventObserver)
            .flatMapError { [client, repository] error -> SignalProducer<URL, CarthageError> in
                if !client.isAuthenticated {
                    return SignalProducer(error: error)
                }
                return GitHubBinariesCache.downloadMatchingBinary(
                    for: dependency,
                    pinnedVersion: pinnedVersion,
                    configuration: configuration,
                    swiftVersion: swiftVersion,
                    destinationURL: destinationURL,
                    fromRepository: repository,
                    client: Client(server: client.server, isAuthenticated: false),
                    eventObserver: eventObserver
                )
            }
            .then(SignalProducer<(), CarthageError>.empty)
    }

    private static func downloadMatchingBinary(
        for dependency: Dependency,
        pinnedVersion: PinnedVersion,
        configuration: String,
        swiftVersion: PinnedVersion,
        destinationURL: URL,
        fromRepository repository: Repository,
        client: Client,
        eventObserver: Signal<ProjectEvent, NoError>.Observer?
        ) -> SignalProducer<URL, CarthageError> {
        return client.execute(repository.release(forTag: pinnedVersion.commitish))
            .map { _, release in release }
            .filter { release in
                return !release.isDraft && !release.assets.isEmpty
            }
            .flatMapError { error -> SignalProducer<Release, CarthageError> in
                switch error {
                case .doesNotExist:
                    return .empty

                case let .apiError(_, _, error):
                    // Log the GitHub API request failure, not to error out,
                    // because that should not be fatal error.
                    eventObserver?.send(value: .skippedDownloadingBinaries(dependency, error.message))
                    return .empty

                default:
                    return SignalProducer(error: .gitHubAPIRequestFailed(error))
                }
            }
            .flatMap(.concat) { release -> SignalProducer<URL, CarthageError> in
                return SignalProducer<Release.Asset, CarthageError>(release.assets)
                    .filter { asset in
                        if asset.name.range(of: Constants.Project.binaryAssetPattern) == nil {
                            return false
                        }
                        return Constants.Project.binaryAssetContentTypes.contains(asset.contentType)
                    }
                    .take(first: 1)
                    .flatMap(.concat) { asset -> SignalProducer<URL, CarthageError> in
                        eventObserver?.send(value: .downloadingBinaries(dependency, release.nameWithFallback))
                        return client.download(asset: asset)
                            .mapError(CarthageError.gitHubAPIRequestFailed)
                            .flatMap(.concat) { downloadURL in
                                Files.moveFile(from: downloadURL, to: destinationURL)
                        }
                }
        }
    }
}

class ExternalTaskBinariesCache: AbstractBinariesCache {

    let taskCommand: String

    init(taskCommand: String) {
        self.taskCommand = taskCommand
    }

    override func downloadBinary(for dependency: Dependency, pinnedVersion: PinnedVersion, configuration: String, resolvedDependenciesHash: String, swiftVersion: PinnedVersion, destinationURL: URL, netrc: Netrc?, eventObserver: Signal<ProjectEvent, NoError>.Observer?) -> SignalProducer<(), CarthageError> {
        guard let task = self.task(dependencyName: dependency.name, dependencyVersion: pinnedVersion.description, buildConfiguration: configuration, resolvedDependenciesHash: resolvedDependenciesHash, swiftVersion: swiftVersion.description, targetFilePath: destinationURL.path) else {
            return SignalProducer<(), CarthageError>.empty
        }
        let versionString = pinnedVersion.description
        return task.launch()
            .mapError(CarthageError.taskError)
            .on(started: {
                eventObserver?.send(value: .downloadingBinaries(dependency, versionString))
            })
            .then(SignalProducer<(), CarthageError>.empty)
    }

    private func task(dependencyName: String, dependencyVersion: String, buildConfiguration: String, resolvedDependenciesHash: String, swiftVersion: String, targetFilePath: String) -> Task? {

        guard !taskCommand.isEmpty else {
            return nil
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CARTHAGE_CACHE_DEPENDENCY_NAME"] = dependencyName
        environment["CARTHAGE_CACHE_DEPENDENCY_HASH"] = resolvedDependenciesHash
        environment["CARTHAGE_CACHE_DEPENDENCY_VERSION"] = dependencyVersion
        environment["CARTHAGE_CACHE_BUILD_CONFIGURATION"] = buildConfiguration
        environment["CARTHAGE_CACHE_SWIFT_VERSION"] = swiftVersion
        environment["CARTHAGE_CACHE_TARGET_FILE_PATH"] = targetFilePath

        return Task(launchCommand: self.taskCommand, environment: environment)
    }
}

class LocalBinariesCache: ExternalTaskBinariesCache {

    init() {
        super.init(taskCommand: "")
    }
}
