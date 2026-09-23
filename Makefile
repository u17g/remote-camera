# Remote Camera — one SwiftUI codebase, two apps: the iPhone is the camera, the Mac is the remote.
# Build everything without the Xcode GUI. Run from the repo root.
#
#   make gen         : generate RemoteCamera.xcodeproj from project.yml (+ buildServer.json for SourceKit-LSP)
#   make build       : mac_build + ios_build
#   make mac_build   : build the Mac app (the remote)
#   make mac_run     : build it, quit any running copy, launch it
#   make ios_build   : build the iPhone app for the Simulator
#   make ios_run     : install + launch it on the Simulator. The Simulator has no camera, so it
#                      streams a test pattern and a once-a-second tick instead; enough to work on
#                      the Mac side without a phone.
#   make ios_build_device : build for a generic iPhone, unsigned. Compiles the camera code the
#                      Simulator build leaves out; needs no phone and no team.
#   make ios_device  : build for the connected iPhone (registers it on the team if needed),
#                      install + launch via devicectl
#   make clean       : remove the generated project and build products
#
# Knobs:
#   CONFIGURATION=Release   optimised build (default Debug)
#   SIMULATOR="iPhone 17"   which Simulator ios_build / ios_run use
#   DEVICE=<udid>           which iPhone ios_device uses (default: the connected one)
#   TEAM=ABCDE12345         signing team, instead of the one in project.yml
#   XCSETTINGS='A=1 B=2'    extra build settings passed straight to xcodebuild

PROJECT       := RemoteCamera
SCHEME        := RemoteCamera
BUNDLE_ID     := com.ryosukecla.remotecamera
CONFIGURATION ?= Debug
SIMULATOR     ?= iPhone 17 Pro
SPEC          := project.yml
XCODEPROJ     := $(PROJECT).xcodeproj
DERIVED_DATA  := $(CURDIR)/.build/DerivedData
XCSETTINGS    ?=

MAC_DEST      := platform=macOS
SIM_DEST      := platform=iOS Simulator,name=$(SIMULATOR)
MAC_APP       := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(PROJECT).app
SIM_APP       := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphonesimulator/$(PROJECT).app
DEVICE_APP    := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/$(PROJECT).app

XCODEBUILD    := xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) $(XCSETTINGS)
PRETTY        := $(shell command -v xcbeautify 2>/dev/null || echo cat)

TEAM          ?=
TEAM_FLAG     := $(if $(TEAM),DEVELOPMENT_TEAM=$(TEAM),)

# Physical device: pass DEVICE=<hardware udid> to override auto-detection.
# Auto-detection prefers a device whose tunnel is connected, then falls back to the first paired one.
DEVICE ?= $(shell xcrun devicectl list devices --json-output /tmp/remotecamera-devices.json >/dev/null 2>&1 && python3 -c 'import json; d=json.load(open("/tmp/remotecamera-devices.json"))["result"]["devices"]; d=[x for x in d if x["hardwareProperties"].get("platform")=="iOS" and x["hardwareProperties"].get("deviceType")=="iPhone"]; c=[x for x in d if x["connectionProperties"].get("tunnelState")=="connected"]; print((c or d)[0]["hardwareProperties"]["udid"] if (c or d) else "")')

.PHONY: gen lsp build mac_build mac_run ios_build ios_build_device ios_boot ios_run ios_device clean

gen:
	xcodegen generate --spec $(SPEC)
	@$(MAKE) --no-print-directory lsp

# buildServer.json must sit at the LSP workspace root (this directory). Optional: skipped when
# xcode-build-server is not installed.
lsp:
	@if command -v xcode-build-server >/dev/null; then \
	  xcode-build-server config -project $(XCODEPROJ) -scheme $(SCHEME) --build_root $(DERIVED_DATA); \
	fi

build: mac_build ios_build

mac_build: gen
	set -o pipefail; $(XCODEBUILD) -destination '$(MAC_DEST)' build | $(PRETTY)

# Matched on the full path, so the Simulator's copy (also a process named RemoteCamera) survives.
mac_run: mac_build
	-@pkill -f "$(MAC_APP)/Contents/MacOS/$(PROJECT)"
	open "$(MAC_APP)"

ios_build: gen
	set -o pipefail; $(XCODEBUILD) -destination '$(SIM_DEST)' build | $(PRETTY)

ios_build_device: gen
	set -o pipefail; $(XCODEBUILD) -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build | $(PRETTY)

ios_boot:
	@xcrun simctl boot "$(SIMULATOR)" 2>/dev/null || true
	@open -a Simulator

ios_run: ios_build ios_boot
	xcrun simctl install "$(SIMULATOR)" "$(SIM_APP)"
	xcrun simctl launch --terminate-running-process "$(SIMULATOR)" $(BUNDLE_ID)

ios_device: gen
	@test -n "$(DEVICE)" || { echo "No paired iPhone found. Connect one or pass DEVICE=<udid>."; exit 1; }
	set -o pipefail; $(XCODEBUILD) -destination "id=$(DEVICE)" -allowProvisioningUpdates -allowProvisioningDeviceRegistration $(TEAM_FLAG) build | $(PRETTY)
	xcrun devicectl device install app --device "$(DEVICE)" "$(DEVICE_APP)"
	xcrun devicectl device process launch --terminate-existing --device "$(DEVICE)" $(BUNDLE_ID)

clean:
	rm -rf $(XCODEPROJ) .build buildServer.json RemoteCamera/Info.plist
