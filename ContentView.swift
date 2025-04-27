import SwiftUI
import AppKit
import SQLite3

struct AppUsage: Identifiable {
    let id = UUID()
    let name: String
    var timeSpent: TimeInterval
}

struct WebsiteUsage: Identifiable {
    let id = UUID()
    let url: String
    var timeSpent: TimeInterval
}

struct ContentView: View {
    @State private var activeApps: [AppUsage] = []
    @State private var visitedWebsites: [WebsiteUsage] = []
    @State private var timer: Timer?
    @State private var chromeHistoryPath: String?
    @State private var lastRefreshTime = Date()
    
    var body: some View {
        VStack {
            Text("Screen Time Tracker").font(.title)
            
            HStack {
                Button(action: {
                    openFilePicker()
                }) {
                    Text("Select History File")
                }
                
                Button(action: {
                    refreshData()
                }) {
                    Text("Refresh Data")
                }
            }
            
            List {
                Section(header: Text("Applications")) {
                    ForEach(activeApps.sorted(by: { $0.timeSpent > $1.timeSpent })) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Text(formatTimeInterval(app.timeSpent))
                        }
                    }
                }
                
                Section(header: Text("Websites (Last 24 Hours)")) {
                    ForEach(visitedWebsites.sorted(by: { $0.timeSpent > $1.timeSpent })) { site in
                        HStack {
                            Text(site.url)
                            Spacer()
                            Text(formatTimeInterval(site.timeSpent))
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 500, height: 600)
        .onAppear { startTracking() }
        .onDisappear { timer?.invalidate() }
    }
    
    // MARK: - Time Formatting
    func formatTimeInterval(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: interval) ?? "0s"
    }
    
    // MARK: - Tracking Logic
    func startTracking() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            trackActiveApp()
            // Only refresh Chrome history every 5 minutes to reduce load
            if Date().timeIntervalSince(lastRefreshTime) > 300 {
                refreshData()
            }
        }
    }
    
    func refreshData() {
        visitedWebsites.removeAll()
        trackChromeHistory()
        lastRefreshTime = Date()
    }
    
    func trackActiveApp() {
        guard let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName else { return }
        
        if let index = activeApps.firstIndex(where: { $0.name == activeApp }) {
            activeApps[index].timeSpent += 1
        } else {
            activeApps.append(AppUsage(name: activeApp, timeSpent: 1))
        }
    }
    
    // MARK: - File Handling
    func openFilePicker() {
        let openPanel = NSOpenPanel()
        openPanel.allowedFileTypes = ["sqlite", "db"]
        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                chromeHistoryPath = url.path
                refreshData()
            }
        }
    }
    
    func trackChromeHistory() {
        guard let path = chromeHistoryPath else { return }
        
        do {
            let tempPath = try copyToTempFile(originalPath: path)
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            
            queryChromeHistory(from: tempPath)
        } catch {
            print("Error copying history file: \(error)")
        }
    }
    
    func copyToTempFile(originalPath: String) throws -> String {
        let tempPath = NSTemporaryDirectory() + "chrome_history_temp_\(Date().timeIntervalSince1970).db"
        try FileManager.default.copyItem(atPath: originalPath, toPath: tempPath)
        return tempPath
    }
    
    // MARK: - Chrome History Query
    func queryChromeHistory(from path: String) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            print("Failed to open database")
            return
        }
        defer { sqlite3_close(db) }
        
        // Chrome's actual schema columns we can use:
        // urls: id, url, title, visit_count, last_visit_time
        // visits: id, url, visit_time, from_visit, transition
        
        // 1. Get current timestamp in Chrome's format
        let chromeTimeCutoff = convertToChromeTime(Date().addingTimeInterval(-86400))
        
        // 2. Query visits with actual available columns
        let visitsQuery = """
        SELECT
            urls.url,
            visits.visit_time,
            visits.from_visit,
            visits.transition
        FROM visits
        JOIN urls ON visits.url = urls.id
        WHERE visits.visit_time >= \(chromeTimeCutoff)
        ORDER BY visits.visit_time ASC
        """
        
        var domainTime: [String: TimeInterval] = [:]
        var previousVisit: (url: String, time: Double)? = nil
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, visitsQuery, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let urlPtr = sqlite3_column_text(statement, 0) else { continue }
                let url = String(cString: urlPtr)
                guard !isInternalURL(url), let domain = extractDomain(from: url) else { continue }
                
                let chromeTime = Double(sqlite3_column_int64(statement, 1))
                let visitTime = (chromeTime / 1_000_000) - 11644473600
                let transition = sqlite3_column_int(statement, 3)
                
                // Filter transitions - only count actual navigation events
                // Core transition types:
                // 0: LINK, 1: TYPED, 2: AUTO_BOOKMARK, 3: AUTO_SUBFRAME, etc.
                let coreTransition = transition & 0xFF
                guard coreTransition == 0 || coreTransition == 1 else { continue }
                
                if let prev = previousVisit {
                    let timeSpent = visitTime - prev.time
                    
                    // Only count reasonable durations (5 sec to 1 hour)
                    if timeSpent > 5 && timeSpent < 3600 {
                        domainTime[prev.url, default: 0] += timeSpent
                    }
                }
                
                previousVisit = (url: domain, time: visitTime)
            }
            sqlite3_finalize(statement)
        }
        
        // 3. Add time for current session if browser is active
        if let currentApp = NSWorkspace.shared.frontmostApplication?.localizedName,
           currentApp == "Google Chrome",
           let lastVisit = previousVisit {
            
            let currentTime = Date().timeIntervalSince1970
            let activeTime = currentTime - lastVisit.time
            
            if activeTime > 0 && activeTime < 3600 {
                domainTime[lastVisit.url, default: 0] += activeTime
            }
        }
        
        // 4. Update UI
        visitedWebsites = domainTime.map { url, time in
            WebsiteUsage(url: url, timeSpent: time)
        }.sorted {
            $0.timeSpent > $1.timeSpent
        }
    }

    // Helper to check if Chrome is currently active
    func isChromeActive() -> Bool {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome"
    }
    
    // MARK: - Helper Functions
    func convertToChromeTime(_ date: Date) -> Int64 {
        // Chrome time is microseconds since Jan 1, 1601
        let unixEpoch = date.timeIntervalSince1970
        let chromeEpoch = unixEpoch + 11644473600 // Seconds between 1601 and 1970
        return Int64(chromeEpoch * 1_000_000) // Convert to microseconds
    }
    
    func isInternalURL(_ url: String) -> Bool {
        let internalPrefixes = [
            "chrome://", "chrome-extension://", "about:",
            "data:", "file:", "blob:", "javascript:"
        ]
        return internalPrefixes.contains { url.hasPrefix($0) }
    }
    
    func extractDomain(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host else { return nil }
        
        // Remove www. prefix if present
        return host.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }
}
