# Adds a UI-test target only to the runner's disposable source copy.
from pathlib import Path
import sys
r=Path(sys.argv[1])
bundle=sys.argv[2]
assert bundle.startswith("com.jongalante.Feast.KeyboardRegression.")
assert "Isolated, synthetic-only UI harness" in (r/'Feast/App/FeastApp.swift').read_text(), "Not a synthetic source copy"
p=r/'Feast.xcodeproj/project.pbxproj';s=p.read_text()
assert "A10000000000000000000007" not in s, "UI target already installed"
assert s.count("PRODUCT_BUNDLE_IDENTIFIER = com.jongalante.Feast;") == 2, "Unexpected app identity"
objects='''
A10000000000000000000001 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = KeyboardGestureTests.swift; sourceTree = "<group>"; };
A10000000000000000000002 = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = KeyboardGestureTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
A10000000000000000000003 = {isa = PBXBuildFile; fileRef = A10000000000000000000001; };
A10000000000000000000004 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A10000000000000000000003,); runOnlyForDeploymentPostprocessing = 0; };
A10000000000000000000005 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
A10000000000000000000006 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
A10000000000000000000007 = {isa = PBXNativeTarget; buildConfigurationList = A10000000000000000000008; buildPhases = (A10000000000000000000004,A10000000000000000000005,A10000000000000000000006,); buildRules = (); dependencies = (A1000000000000000000000C,); name = KeyboardGestureTests; productName = KeyboardGestureTests; productReference = A10000000000000000000002; productType = "com.apple.product-type.bundle.ui-testing"; };
A10000000000000000000008 = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000009,A1000000000000000000000A,); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
A10000000000000000000009 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = com.jongalante.Feast.KeyboardQA20261112.tests; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = 1; IPHONEOS_DEPLOYMENT_TARGET = 18.6; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; TEST_TARGET_NAME = Feast; CODE_SIGN_ENTITLEMENTS = ""; }; };
A1000000000000000000000A = {isa = XCBuildConfiguration; name = Release; buildSettings = {GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = com.jongalante.Feast.KeyboardQA20261112.tests; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = 1; IPHONEOS_DEPLOYMENT_TARGET = 18.6; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; TEST_TARGET_NAME = Feast; CODE_SIGN_ENTITLEMENTS = ""; }; };
A1000000000000000000000B = {isa = PBXContainerItemProxy; containerPortal = 124EB5772F70564600FAEEA9; proxyType = 1; remoteGlobalIDString = 124EB57E2F70564600FAEEA9; remoteInfo = Feast; };
A1000000000000000000000C = {isa = PBXTargetDependency; target = 124EB57E2F70564600FAEEA9; targetProxy = A1000000000000000000000B; };
'''
s=s.replace('objects = {','objects = {\n'+objects,1)
s=s.replace('124EB5812F70564600FAEEA9 /* Feast */,','A10000000000000000000001,\n\t\t\t\t124EB5812F70564600FAEEA9 /* Feast */,',1)
s=s.replace('124EB57F2F70564600FAEEA9 /* Feast.app */,','A10000000000000000000002,\n\t\t\t\t124EB57F2F70564600FAEEA9 /* Feast.app */,',1)
s=s.replace('targets = (','targets = (\n\t\t\t\tA10000000000000000000007,',1)
s=s.replace('PRODUCT_BUNDLE_IDENTIFIER = com.jongalante.Feast;', 'PRODUCT_BUNDLE_IDENTIFIER = com.jongalante.Feast.KeyboardQA20261112;')
s=s.replace("com.jongalante.Feast.KeyboardQA20261112",bundle)
p.write_text(s)
p=r/'Feast.xcodeproj/xcshareddata/xcschemes/Feast.xcscheme';s=p.read_text().replace('   </TestAction>','''      <Testables>
         <TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A10000000000000000000007" BuildableName="KeyboardGestureTests.xctest" BlueprintName="KeyboardGestureTests" ReferencedContainer="container:Feast.xcodeproj" /></TestableReference>
      </Testables>
   </TestAction>''');p.write_text(s)
p=r/'Feast/Features/AskFeast/AskSavedCollectionPanel.swift';s=p.read_text().replace('.accessibilityLabel("Message Ask Feast")','.accessibilityLabel("Message Ask Feast").accessibilityIdentifier("qa.composer")');p.write_text(s)

p=r/'Feast/Features/AskFeast/AskSavedCollectionPanel.swift'
s=p.read_text().replace('.scrollDismissesKeyboard(.interactively)', '.scrollDismissesKeyboard(.interactively)\n                .accessibilityIdentifier("qa.transcript")', 1)
p.write_text(s)

# Fixture-only photo controls; no capabilities request or real photo library access.
p=r/'Feast/Features/AskFeast/AskFeastTabState.swift'
s=p.read_text().replace('var screenshotSendingAvailable = false', 'var screenshotSendingAvailable = ProcessInfo.processInfo.arguments.contains("-photos")', 1)
p.write_text(s)
