import Foundation
import Swifter

public final class HlsServer: HttpServer {
	var targetSegmentLength: Int = 3
	let segmentLength: TimeInterval = 2.9866666
	let seekingWindowInSeconds: TimeInterval = 18_000 // 5h
	let skippableSegments = 6
	var isStale: Bool = false {
		didSet {
			guard isStale != oldValue else { return }

			if isStale {
				stopScheduledPlaylistUpdates()
			} else {
				startScheduledPlaylistUpdates()
			}
		}
	}
	let path: String
	let segmentsPath: String = "segments"
	let livestreamPlaylistFilename = "main-ios.m3u8"
	let livestreamVariantFilename = "main-128000-ios.m3u8"
	var livestreamUrl: URL? {
		guard
			let port = try? self.port()
		else {
			return nil
		}
		return URL(string: "http://localhost:\(port)/\(path)/\(livestreamPlaylistFilename)")
	}

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
	let serverToNowDifference: TimeInterval
	var now: Date {
		Date().addingTimeInterval(-serverToNowDifference)
	}

	private var segmentCount: Int { Int(seekingWindowInSeconds / Double(targetSegmentLength)) }
	private let initialMediaSequence = 1_000_000
	private var numberOfPlaylistUpdates = 0
	private var currentPlaylist: String = ""
	private var currentDeltaPlaylist: String = ""

	private var previousDeltaPlaylistResponse: String?
	private var previousPlaylistResponse: String?
	private var previousDate: Date?

	private lazy var timer: DispatchSourceTimer = {
		let t = DispatchSource.makeTimerSource()
		t.schedule(deadline: .now(), repeating: TimeInterval(self.targetSegmentLength))
		t.setEventHandler(handler: { [weak self] in
			self?.updatePlaylist()
		})
		return t
	}()
	private var isTimerSuspended = true

	private lazy var dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(secondsFromGMT: 0)
		return formatter
	}()

	@objc private func updatePlaylist() {

//		if currentMediaSequence >= 1_000_010 {
//			print("playlist is stale now")
//			return
//		}

		// simulate one segment length latency to the live time
		let mostRecentSegmentPDT = now.addingTimeInterval(-segmentLength)

		// this is constant since segments are removed from the top and added to the bottom (5993 in our case)
		let skippedSegments = segmentCount-skippableSegments-1

		var fullPlaylist = """
			#EXTM3U
			#EXT-X-VERSION:3
			#EXT-X-MEDIA-SEQUENCE:\(initialMediaSequence + numberOfPlaylistUpdates)
			#EXT-X-TARGETDURATION:\(targetSegmentLength)
			#EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=\(skippableSegments * targetSegmentLength)
			"""

		var deltaPlayist = fullPlaylist
		deltaPlayist += "\n#EXT-X-SKIP:SKIPPED-SEGMENTS=\(skippedSegments)\n" // this is the total number of skipped segments

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

	deinit {
		timer.setEventHandler {}
		timer.cancel()

		// If the timer is suspended, calling cancel without resuming triggers a crash.
		// This is documented here https://forums.developer.apple.com/thread/15902
		startScheduledPlaylistUpdates()
	}

	private func startScheduledPlaylistUpdates() {
		guard isTimerSuspended else { return }

		print("playlist timer update started")

		timer.resume()
		isTimerSuspended.toggle()
	}

	private func stopScheduledPlaylistUpdates() {
		guard !isTimerSuspended else { return }

		print("playlist timer update stopped")
		timer.suspend()
	}

	public init(path: String = "mockServer",
							serverToNowDifference: TimeInterval = 0) {
		self.path = path
		self.serverToNowDifference = serverToNowDifference

		super.init()

		startScheduledPlaylistUpdates()

		// segments
		self["/\(path)/\(segmentsPath)/:segmentName"] = { request in
			print("request path is \(request.path)")

			let filePath = Bundle.module.resourcePath! + "/segments/sample.ts"

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
			return .ok(
				.data("""
					#EXTM3U
					#EXT-X-VERSION:3
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
				let response = self.currentDeltaPlaylist
				self.previousDeltaPlaylistResponse = response
				return .ok(.data(response.data(using: .utf8)!, contentType: "application/vnd.apple.mpegurl"))
			} else {
				let response = self.currentPlaylist
				self.previousPlaylistResponse = response
				return .ok(.data(response.data(using: .utf8)!, contentType: "application/vnd.apple.mpegurl"))
			}
		}

		self.notFoundHandler = { request in
			print("Not found handler called \(dump(request))")
			return .notFound
		}
	}
}
