//
//  Favicons.swift
//  DuckDuckGo
//
//  Copyright © 2020 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Kingfisher
import UIKit
import os
import LinkPresentation

// swiftlint:disable type_body_length file_length
public class Favicons {

    public struct Constants {

        static let salt = "DDGSalt:"
        static let faviconsFolderName = "Favicons"
        static let requestModifier = FaviconRequestModifier()
        static let bookmarksCache = CacheType.bookmarks.create()
        static let tabsCache = CacheType.tabs.create()
        static let appUrls = AppUrls()
        static let targetImageSizePoints: CGFloat = 64
        public static let maxFaviconSize: CGSize = CGSize(width: 192, height: 192)
        
        public static let caches = [
            CacheType.bookmarks: bookmarksCache,
            CacheType.tabs: tabsCache
        ]

    }

    public enum CacheType: String {

        case tabs
        case bookmarks

        func create() -> ImageCache {
            
            // If unable to create cache in desired location default to Kinfisher's default location which is Library/Cache.  Images may disappear
            //  but at least the app won't crash.  This should not happen.
            let cache = createCacheInDesiredLocation() ?? ImageCache(name: rawValue)
            
            // We hash the resource key when loading the resource so don't use Kingfisher's hashing which is md5 based
            cache.diskStorage.config.usesHashedFileName = false
            
            return cache
        }

        public func cacheLocation() -> URL? {
            return baseCacheURL()?.appendingPathComponent(Constants.faviconsFolderName)
        }

        private func createCacheInDesiredLocation() -> ImageCache? {
            
            guard var url = cacheLocation() else { return nil }
            
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url,
                                        withIntermediateDirectories: true,
                                        attributes: nil)
                
                // Exclude from backup
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                try? url.setResourceValues(resourceValues)
            }
            
            os_log("favicons %s location %s", type: .debug, rawValue, url.absoluteString)
            return try? ImageCache(name: self.rawValue, cacheDirectoryURL: url)
        }

        private func baseCacheURL() -> URL? {
            switch self {
            case .bookmarks:
                let groupName = BookmarkUserDefaults.Constants.groupName
                return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupName)
                       
            case .tabs:
                return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            }
        }
        
    }

    public static let shared = Favicons()

    @UserDefaultsWrapper(key: .faviconsNeedMigration, defaultValue: true)
    var needsMigration: Bool

    @UserDefaultsWrapper(key: .faviconSizeNeedsMigration, defaultValue: true)
    var sizeNeedsMigration: Bool

    let sourcesProvider: FaviconSourcesProvider
    let bookmarksStore: BookmarkStore
    let bookmarksCachingSearch: BookmarksCachingSearch
    let downloader: NotFoundCachingDownloader

    let userAgentManager: UserAgentManager = DefaultUserAgentManager.shared

    init(sourcesProvider: FaviconSourcesProvider = DefaultFaviconSourcesProvider(),
         bookmarksStore: BookmarkStore = BookmarkUserDefaults(),
         bookmarksCachingSearch: BookmarksCachingSearch = CoreDependencyProvider.shared.bookmarksCachingSearch,
         downloader: NotFoundCachingDownloader = NotFoundCachingDownloader()) {
        self.sourcesProvider = sourcesProvider
        self.bookmarksStore = bookmarksStore
        self.bookmarksCachingSearch = bookmarksCachingSearch
        self.downloader = downloader

        // Prevents the caches being cleaned up
        NotificationCenter.default.removeObserver(Constants.bookmarksCache)
        NotificationCenter.default.removeObserver(Constants.tabsCache)
    }
    
    public func migrateIfNeeded(afterMigrationHandler: @escaping () -> Void) {
        guard needsMigration else { return }

        DispatchQueue.global(qos: .utility).async {
            ImageCache.default.clearDiskCache()
            
            let links = ((self.bookmarksStore.bookmarks + self.bookmarksStore.favorites).compactMap { $0.url.host })
                + PreserveLogins.shared.allowedDomains
            
            let group = DispatchGroup()
            Set(links).forEach { domain in
                group.enter()
                self.loadFavicon(forDomain: domain, intoCache: .bookmarks) { _ in
                    group.leave()
                }
            }
            group.wait()

            self.needsMigration = false
            afterMigrationHandler()
        }
        
    }

    public func migrateFavicons(to size: CGSize, afterMigrationHandler: @escaping () -> Void) {
        guard sizeNeedsMigration else { return }

        DispatchQueue.global(qos: .utility).async {
            guard let files = try? FileManager.default.contentsOfDirectory(at: Constants.bookmarksCache.diskStorage.directoryURL,
                    includingPropertiesForKeys: nil) else {
                return
            }

            let group = DispatchGroup()
            files.forEach { file in
                group.enter()
                guard let data = (try? Data(contentsOf: file)),
                      let image = UIImage(data: data),
                      !self.isValidImage(image, forMaxSize: size) else {
                    group.leave()
                    return
                }

                let resizedImage = self.resizedImage(image, toSize: size)
                if let data = resizedImage.pngData() {
                    try? data.write(to: file)
                }
                group.leave()
            }
            group.wait()

            Constants.bookmarksCache.clearMemoryCache()
            self.sizeNeedsMigration = false
            afterMigrationHandler()
        }
    }

    internal func isValidImage(_ image: UIImage, forMaxSize size: CGSize) -> Bool {
        if image.size.width > size.width || image.size.height > size.height {
            return false
        }
        return true
    }

    internal func resizedImage(_ image: UIImage, toSize size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func replaceBookmarksFavicon(forDomain domain: String?, withImage image: UIImage) {
        
        guard let domain = domain,
              let resource = defaultResource(forDomain: domain),
              let options = kfOptions(forDomain: domain, usingCache: .bookmarks) else { return }

        if !isFaviconCachedForBookmarks(forDomain: domain, resource: resource) {
            loadFaviconForBookmarks(forDomain: domain)
            return
        }

        let replace = {
            Constants.bookmarksCache.removeImage(forKey: resource.cacheKey)
            Constants.bookmarksCache.store(image, forKey: resource.cacheKey, options: .init(options))
        }
        
        // only replace if it exists and new one is bigger
        Constants.bookmarksCache.retrieveImageInDiskCache(forKey: resource.cacheKey, options: [.onlyFromCache ]) { result in
            switch result {
                
            case .success(let cachedImage):
                if let cachedImage = cachedImage, cachedImage.size.width < image.size.width {
                    replace()
                } else if self.bookmarksStore.contains(domain: domain) {
                    replace()
                }
                
            default:
                break
            }
        }
    }

    func isFaviconCachedForBookmarks(forDomain domain: String, resource: ImageResource) -> Bool {
        return Constants.bookmarksCache.isCached(forKey: resource.cacheKey) || bookmarksStore.contains(domain: domain)
    }

    func loadFaviconForBookmarks(forDomain domain: String) {
        // If the favicon is not cached for bookmarks, we need to:
        // 1. check if a bookmark exists for the domain
        // 2. if it does, we need to load the favicon for the domain
        if bookmarksCachingSearch.containsDomain(domain) {
            loadFavicon(forDomain: domain, intoCache: .bookmarks, fromCache: .tabs)
        }
    }

    public func clearCache(_ cacheType: CacheType) {
        Constants.caches[cacheType]?.clearDiskCache()
    }

    private func removeFavicon(forDomain domain: String, fromCache cacheType: CacheType) {
        let key = defaultResource(forDomain: domain)?.cacheKey ?? domain
        Constants.caches[cacheType]?.removeImage(forKey: key, fromDisk: true)
    }

    public func removeBookmarkFavicon(forDomain domain: String) {

        guard !PreserveLogins.shared.isAllowed(fireproofDomain: domain) else { return }
        removeFavicon(forDomain: domain, fromCache: .bookmarks)

    }

    public func removeFireproofFavicon(forDomain domain: String) {

        guard !bookmarksStore.contains(domain: domain) else { return }
        removeFavicon(forDomain: domain, fromCache: .bookmarks)

    }
    
    private func copyFavicon(forDomain domain: String, fromCache: CacheType, toCache: CacheType, completion: ((UIImage?) -> Void)? = nil) {
        guard let resource = defaultResource(forDomain: domain),
             let options = kfOptions(forDomain: domain, usingCache: toCache) else { return }
        
        Constants.caches[fromCache]?.retrieveImage(forKey: resource.cacheKey, options: [.onlyFromCache]) { result in
            switch result {
            case .success(let image):
                if let image = image.image {
                    Constants.caches[toCache]?.store(image, forKey: resource.cacheKey, options: .init(options))
                }
                completion?(image.image)

            default:
                completion?(nil)
            }
        }
        return
    }

    // Call this when the user interacts with an entity of the specific type with a given URL,
    //  e.g. if launching a bookmark, or clicking on a tab.
    public func loadFavicon(forDomain domain: String?,
                            fromURL url: URL? = nil,
                            intoCache targetCacheType: CacheType,
                            fromCache: CacheType? = nil,
                            queue: DispatchQueue? = OperationQueue.current?.underlyingQueue,
                            completion: ((UIImage?) -> Void)? = nil) {

        guard let domain = domain,
            let options = kfOptions(forDomain: domain, withURL: url, usingCache: targetCacheType),
            let resource = defaultResource(forDomain: domain),
            let targetCache = Favicons.Constants.caches[targetCacheType] else {
                completion?(nil)
                return
            }
        
        if let fromCache = fromCache, Constants.caches[fromCache]?.isCached(forKey: resource.cacheKey) ?? false {
            copyFavicon(forDomain: domain, fromCache: fromCache, toCache: targetCacheType, completion: completion)
            return
        }

        guard let queue = queue else { return }

        func complete(withImage image: UIImage?) {
            queue.async {
                if var image = image {
                    if !self.isValidImage(image, forMaxSize: Constants.maxFaviconSize) {
                        image = self.resizedImage(image, toSize: Constants.maxFaviconSize)
                    }
                    targetCache.store(image, forKey: resource.cacheKey, options: .init(options))
                }
                completion?(image)
            }
        }

        targetCache.retrieveImage(forKey: resource.cacheKey, options: options) { result in

            var image: UIImage?

            switch result {

            case .success(let result):
                image = result.image

            default: break
            }

            if let image = image {
                complete(withImage: image)
            } else {
                self.loadImageFromNetwork(url, domain, complete)
            }

        }

    }

    private func loadImageFromNetwork(_ imageUrl: URL?,
                                      _ domain: String,
                                      _ completion: @escaping (UIImage?) -> Void) {

      guard downloader.shouldDownload(forDomain: domain) else {
            completion(nil)
            return
        }

        let bestSources = [
            imageUrl,
            sourcesProvider.mainSource(forDomain: domain)
        ].compactMap { $0 }

        let additionalSources = sourcesProvider.additionalSources(forDomain: domain)

        // Try LinkPresentation first, before falling back to standard favicon fetching logic.
        retrieveLinkPresentationImage(from: domain) {
            guard let image = $0, image.size.width >= Constants.targetImageSizePoints else {
                self.retrieveBestImage(bestSources: bestSources, additionalSources: additionalSources, completion: completion)
                return
            }

            completion(image)
        }
    }

    private func retrieveBestImage(bestSources: [URL], additionalSources: [URL], completion: @escaping (UIImage?) -> Void) {
        retrieveBestImage(from: bestSources) {

            // Fallback to favicons
            guard let image = $0 else {
                self.retrieveBestImage(from: additionalSources) {
                    completion($0)
                }
                return
            }

            completion(image)
        }
    }

    private func retrieveLinkPresentationImage(from domain: String, completion: @escaping (UIImage?) -> Void) {
        guard let url = URL(string: "https://\(domain)") else {
            completion(nil)
            return
        }

        let metadataFetcher = LPMetadataProvider()
        let completion: (LPLinkMetadata?, Error?) -> Void = { metadata, metadataError in
            guard let iconProvider = metadata?.iconProvider, metadataError == nil else {
                completion(nil)
                return
            }

            iconProvider.loadObject(ofClass: UIImage.self) { potentialImage, _ in
                completion(potentialImage as? UIImage)
            }
        }

        if #available(iOS 15.0, *) {
            let request = URLRequest.userInitiated(url)
            metadataFetcher.startFetchingMetadata(for: request, completionHandler: completion)
        } else {
            metadataFetcher.startFetchingMetadata(for: url, completionHandler: completion)
        }
    }

    private func retrieveBestImage(from urls: [URL], completion: @escaping (UIImage?) -> Void) {
        let targetSize = Constants.targetImageSizePoints * UIScreen.main.scale
        DispatchQueue.global(qos: .background).async {
            var bestImage: UIImage?
            for url in urls {
                guard let image = self.loadImage(url: url) else { continue }
                if (bestImage?.size.width ?? 0) < image.size.width {
                    bestImage = image
                    if image.size.width >= targetSize {
                        break
                    }
                }
            }
            completion(bestImage)
        }
    }

    private func loadImage(url: URL) -> UIImage? {
        var image: UIImage?
        var request = URLRequest.userInitiated(url)
        userAgentManager.update(request: &request, isDesktop: false)

        let group = DispatchGroup()
        group.enter()
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data {
                image = UIImage(data: data)
            }
            group.leave()
        }
        task.resume()
        _ = group.wait(timeout: .now() + 60.0)
        return image
    }

    public func defaultResource(forDomain domain: String?) -> ImageResource? {
        return FaviconsHelper.defaultResource(forDomain: domain, sourcesProvider: sourcesProvider)
    }

    public func kfOptions(forDomain domain: String?, withURL url: URL? = nil, usingCache cacheType: CacheType) -> KingfisherOptionsInfo? {
        guard let domain = domain else {
            return nil
        }

        if Constants.appUrls.isDuckDuckGo(domain: domain) {
            return nil
        }

        guard let cache = Constants.caches[cacheType] else {
            return nil
        }

        var sources = sourcesProvider.additionalSources(forDomain: domain).map { Source.network($0) }
        
        // a provided URL was given so add our usual main source to the list of alteratives
        if let url = url {
            sources.insert(Source.network(url), at: 0)
        }

        // Explicity set the expiry
        let expiry = KingfisherOptionsInfoItem.diskCacheExpiration(isDebugBuild ? .seconds(60) : .days(7))

        return [
            .downloader(downloader),
            .requestModifier(Constants.requestModifier),
            .targetCache(cache),
            expiry,
            .alternativeSources(sources)
        ]
    }

    public static func createHash(ofDomain domain: String) -> String {
        return "\(Constants.salt)\(domain)".sha256()
    }

}
// swiftlint:enable type_body_length file_length
