import Foundation
import os.log
import Swifter

public final class HlsServer: HttpServer {
	public var isStale: Bool = false
	public let livestreamPlaylistFilename: String
	public var livestreamUrl: URL? {
		guard
			let port = try? self.port()
		else {
			return nil
		}
		return URL(string: "http://localhost:\(port)/\(path)/\(livestreamPlaylistFilename)")
	}
	public var now: Date {
		Date().addingTimeInterval(-serverToNowDifference)
	}
	public let path: String
	public let seekingWindowInSeconds: TimeInterval
	public let segmentLength: TimeInterval

	/// The difference in seconds between the server time and the client time.
	///
	/// If the client uses a fixed time for testing this can be helpful to register the initial offset between the client and the server.
	/// This way even a "live" stream can be simulated.
	///
	/// ```
	/// let fixedClientDate = Date(timeIntervalSince1970: 1_000)
	/// let server = HlsServer(serverToNowDifference: Date().timeInverval(since: fixedClientDate))
	/// ```
	/// The server now serves a playlist that uses the `seekingWindowInSeconds` and `serverToNowDifference` to simulate how
	/// a livestream would have been encoded on that given date.
	///
	/// Note: Your client should only use the fixed date at startup to register the difference to the device time so the simulated time progresses as the
	/// time on the device passes.
	/// This could be used in the following fashion:
	///
	/// ```
	/// struct Environment {
	///   now: () -> Date
	/// }
	///
	/// let fixedStartupDate = Date(timeIntervalSince1970: 1_000)
	/// let deviceStartupDate = Date()
	/// let Current = Environment(
	///   now: {
	///     let diff = deviceStartupDate.timeIntervalSince(fixedStartupDate)
	///     return Date().addingTimeInterval(-diff)
	///   }
	/// )
	/// ```
	/// This way the time passes in realtime relative to a fixed start date.
	public let serverToNowDifference: TimeInterval

	public let skippableSegments: Int
	public let targetSegmentLength: Int

	/// Creates an `HlsServer` instance.
	/// - Parameters:
	///   - livestreamPlaylistFilename: The name of the playlist. Defaults to `main-ios.m3u8`.
	///   - path: The path to register for hls. Defaults to `mockServer`.
	///   - seekingWindowInSeconds: The seeking in window in seconds. Defaults to five hours.
	///   - segmentLength: The actual segment length in seconds. Defaults to `2.9866666`.
	///   - skippableSegments: This value + 1 determines the number of segments returned for delta updates. Defaults to `6`.
	///   - targetSegmentLength: The target duration of a segment (`#EXT-X-TARGETDURATION`). Defaults to `3`.
	///   - serverToNowDifference: The time difference between the client and the server. Defaults to `0`. See ``serverToNowDifference``.
	public init(livestreamPlaylistFilename: String = "main-ios.m3u8",
							path: String = "mockServer",
							seekingWindowInSeconds: TimeInterval = 18_000,
							segmentLength: TimeInterval = 2.9866666,
							skippableSegments: Int = 6,
							targetSegmentLength: Int = 3,
							serverToNowDifference: TimeInterval = 0) {
		self.livestreamPlaylistFilename = livestreamPlaylistFilename
		self.path = path
		self.seekingWindowInSeconds = seekingWindowInSeconds
		self.segmentLength = segmentLength
		self.skippableSegments = skippableSegments
		self.targetSegmentLength = targetSegmentLength
		self.serverToNowDifference = serverToNowDifference

		super.init()

		startScheduledPlaylistUpdates()

		// segments
		self["/\(path)/\(segmentsPath)/:segmentName"] = { request in
			os_log("request path is %{public}@", log: log, type: .info, request.path)

			let filePath = Bundle.module.resourcePath! + "/segments/sample\(self.segmentFileIndex).ts"

			os_log("streaming file from %{public}@", log: log, type: .info, filePath)

			if let file = try? filePath.openForReading() {
				var responseHeader: [String: String] = ["Content-Type": "video/mp2t"]

				if let attr = try? FileManager.default.attributesOfItem(atPath: filePath),
					 let fileSize = attr[FileAttributeKey.size] as? UInt64 {
					responseHeader["Content-Length"] = String(fileSize)
				}

				return .raw(200, "OK", responseHeader, { writer in
					try? writer.write(file)
					file.close()
				})
			}
			return .notFound
		}

		self["/\(path)/\(livestreamPlaylistFilename)"] = { request in
			os_log("request main playlist", log: log, type: .info)

			return .ok(
				.data("""
					#EXTM3U
					#EXT-X-VERSION:9
					#EXT-X-ALLOW-CACHE:NO
					## Created with Z/IPStream R/2 v1.08.09
					#EXT-X-STREAM-INF:BANDWIDTH=137557,CODECS="mp4a.40.2"
					\(self.livestreamVariantFilename)
					""".data(using: .utf8)!,
							contentType: "application/vnd.apple.mpegurl"
				)
			)
		}

		self["/\(path)/\(livestreamVariantFilename)"] = { [weak self] request in
			guard let self = self else { return .internalServerError }

			if request.queryParams.contains(where: { (key, value) in key == "_HLS_skip" && value == "YES" }) {
				os_log("requesting delta variant playlist", log: log, type: .info)
				return .ok(.data(self.currentDeltaPlaylist.data(using: .utf8)!, contentType: "application/vnd.apple.mpegurl"))
			} else {
				os_log("requesting variant playlist", log: log, type: .info)
				return .ok(.data(self.currentPlaylist.data(using: .utf8)!, contentType: "application/vnd.apple.mpegurl"))
			}
		}
	}

	deinit {
		timer.setEventHandler {}
		timer.cancel()

		// If the timer is suspended, calling cancel without resuming triggers a crash.
		// This is documented here https://forums.developer.apple.com/thread/15902
		startScheduledPlaylistUpdates()
	}

	private var currentDeltaPlaylist: String = ""
	private var currentPlaylist: String = ""

	private lazy var dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(secondsFromGMT: 0)
		return formatter
	}()

	private let initialMediaSequence = 1_000_000
	private var isTimerSuspended = true

	private let livestreamVariantFilename = "main-128000-ios.m3u8"
	private var numberOfPlaylistUpdates = 0
	private var previousSegmentIndex = 0
	private var segmentCount: Int { Int(seekingWindowInSeconds / Double(targetSegmentLength)) }

	private var segmentFileIndex: Int {
		defer { previousSegmentIndex = (previousSegmentIndex + 1) % segmentIndices.count }
		return segmentIndices[previousSegmentIndex]
	}
	private var segmentIndices = Array(0...9)
	private let segmentsPath = "segments"

	private lazy var timer: DispatchSourceTimer = {
		let t = DispatchSource.makeTimerSource()
		t.schedule(deadline: .now(), repeating: TimeInterval(self.targetSegmentLength))
		t.setEventHandler(handler: { [weak self] in
			self?.updatePlaylist()
		})
		return t
	}()

	@objc private func updatePlaylist() {
		guard !isStale else { return }

		let mostRecentSegmentPDT = now

		// this is constant since segments are removed from the top and added to the bottom (5993 in our case)
		let skippedSegments = segmentCount-skippableSegments-1

		var fullPlaylist = """
			#EXTM3U
			#EXT-X-VERSION:9
			#EXT-X-MEDIA-SEQUENCE:\(initialMediaSequence + numberOfPlaylistUpdates)
			#EXT-X-TARGETDURATION:\(targetSegmentLength)
			#EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=\(skippableSegments * targetSegmentLength)
			"""

		var deltaPlayist = fullPlaylist
		deltaPlayist += "\n#EXT-X-SKIP:SKIPPED-SEGMENTS=\(skippedSegments)" // this is the total number of skipped segments

		for segmentIndex in numberOfPlaylistUpdates ..< segmentCount + numberOfPlaylistUpdates {
			let inverseIndex = segmentCount + numberOfPlaylistUpdates - segmentIndex - 1
			let pdt = mostRecentSegmentPDT.addingTimeInterval(-TimeInterval(inverseIndex)*segmentLength)

			fullPlaylist.append("""

			#EXT-X-PROGRAM-DATE-TIME:\(dateFormatter.string(from: pdt))
			#EXTINF:\(segmentLength),
			\(segmentsPath)/\(segmentIndex).ts
			""")

			// only take the last `skippableSegments + 1` into delta playlist
			if segmentIndex >= segmentCount + numberOfPlaylistUpdates - skippableSegments - 1 {
				deltaPlayist.append("""

				#EXT-X-PROGRAM-DATE-TIME:\(dateFormatter.string(from: pdt))
				#EXTINF:\(segmentLength),
				\(segmentsPath)/\(segmentIndex).ts
				""")
			}
		}

		currentPlaylist = fullPlaylist
		currentDeltaPlaylist = deltaPlayist
		numberOfPlaylistUpdates += 1
	}

	private func startScheduledPlaylistUpdates() {
		guard isTimerSuspended else { return }

		os_log("playlist timer update started", log: log, type: .info)

		timer.resume()
		isTimerSuspended.toggle()
	}

	private func stopScheduledPlaylistUpdates() {
		guard !isTimerSuspended else { return }

		os_log("playlist timer update stopped", log: log, type: .info)
		timer.suspend()
	}
}

private let log = OSLog(subsystem: "de.fruitco.hlsmock", category: "server")
