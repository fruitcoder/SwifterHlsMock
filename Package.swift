// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
	name: "SwifterHlsMock",
	platforms: [
		.iOS(.v10),
		.macOS(.v10_12),
		.tvOS(.v10),
		.watchOS(.v3)
	],
	products: [
		.library(
			name: "SwifterHlsMock",
			targets: [
				"SwifterHlsMock"
			]
		),
		.executable(
			name: "Sample",
			targets: [
				"Sample"
			]
		)
	],
	dependencies: [
		.package(
			name: "Swifter",
			url: "https://github.com/httpswift/swifter.git",
			from: "1.5.0"
		)
	],
	targets: [
		.target(
			name: "SwifterHlsMock",
			dependencies: [
				.product(name: "Swifter", package: "Swifter")
			],
			resources: [
				.copy("Resources/segments")
			]
		),
		.target(
			name: "Sample",
			dependencies: [
				"SwifterHlsMock"
			],
			path: "Example"
		),
		.testTarget(
			name: "SwifterHlsMockTests",
			dependencies: ["SwifterHlsMock"]
		)
	]
)
