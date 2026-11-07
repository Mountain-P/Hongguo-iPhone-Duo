#!/usr/bin/env python3
"""Generate a dependency-free Xcode project. All app Swift files are discovered here."""
from pathlib import Path
import hashlib
import json
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
VERSION = (ROOT / "VERSION").read_text().strip()
if not re.fullmatch(r"\d+\.\d+\.\d+", VERSION):
    raise ValueError("VERSION must contain a semantic app version")
IOS = ROOT / "iOS"
PROJECT = IOS / "Hongguo.xcodeproj"
PROJECT.mkdir(parents=True, exist_ok=True)

def identifier(value):
    return hashlib.sha1(value.encode()).hexdigest()[:24].upper()

def quoted(value):
    return json.dumps(str(value), ensure_ascii=False)

objects = []
def obj(name, value):
    objects.append(f"\t\t{identifier(name)} = {{ {value} }};")
    return identifier(name)

def sequence(values):
    return "(" + ", ".join(values) + ",)" if values else "()"

source_ids, children, resources = [], [], []
for file in sorted((IOS / "Hongguo").rglob("*.swift")):
    path = str(file.relative_to(IOS))
    ref = obj("file:" + path, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(path)}; sourceTree = SOURCE_ROOT;")
    source_ids.append(obj("build:" + path, f"isa = PBXBuildFile; fileRef = {ref};"))
    children.append(ref)
for path, file_type in [("Hongguo/Assets.xcassets", "folder.assetcatalog"), ("Hongguo/PrivacyInfo.xcprivacy", "text.xml")]:
    ref = obj("file:" + path, f"isa = PBXFileReference; lastKnownFileType = {file_type}; path = {quoted(path)}; sourceTree = SOURCE_ROOT;")
    resources.append(obj("build:" + path, f"isa = PBXBuildFile; fileRef = {ref};"))
    children.append(ref)
app = obj("app", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Hongguo.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj("products", f'isa = PBXGroup; children = ({app},); name = Products; sourceTree = "<group>";')
group = obj("group", f'isa = PBXGroup; children = {sequence(children + [products])}; sourceTree = "<group>";')
package = obj("package", 'isa = XCLocalSwiftPackageReference; relativePath = "..";')
core = obj("core", f"isa = XCSwiftPackageProductDependency; package = {package}; productName = HongguoCore;")
core_build = obj("core-build", f"isa = PBXBuildFile; productRef = {core};")
playback = obj("playback", f"isa = XCSwiftPackageProductDependency; package = {package}; productName = HongguoPlayback;")
playback_build = obj("playback-build", f"isa = PBXBuildFile; productRef = {playback};")
sources = obj("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {sequence(source_ids)}; runOnlyForDeploymentPostprocessing = 0;")
frameworks = obj("frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({core_build}, {playback_build},); runOnlyForDeploymentPostprocessing = 0;")
resources_id = obj("resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {sequence(resources)}; runOnlyForDeploymentPostprocessing = 0;")

project_configs, target_configs = [], []
for configuration in ["Debug", "Release"]:
    debug = configuration == "Debug"
    project_settings = {
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "SDKROOT": "iphoneos",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SWIFT_VERSION": "5.0",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if debug else "-O",
        "DEBUG_INFORMATION_FORMAT": "dwarf" if debug else "dwarf-with-dsym",
        "ENABLE_TESTABILITY": "YES" if debug else "NO",
        "ONLY_ACTIVE_ARCH": "YES" if debug else "NO",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if debug else "",
    }
    target_settings = {
        "PRODUCT_NAME": "Hongguo", "PRODUCT_BUNDLE_IDENTIFIER": "tw.mountainp.hongguo",
        "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "", "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Info.plist", "TARGETED_DEVICE_FAMILY": "1",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO",
        "MARKETING_VERSION": VERSION, "CURRENT_PROJECT_VERSION": "30",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
    }
    def settings(values):
        return " ".join(f"{key} = {quoted(value)};" for key, value in values.items())
    project_configs.append(obj("project:" + configuration, f"isa = XCBuildConfiguration; buildSettings = {{ {settings(project_settings)} }}; name = {configuration};"))
    target_configs.append(obj("target:" + configuration, f"isa = XCBuildConfiguration; buildSettings = {{ {settings(target_settings)} }}; name = {configuration};"))
project_config_list = obj("project-configs", f"isa = XCConfigurationList; buildConfigurations = {sequence(project_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
target_config_list = obj("target-configs", f"isa = XCConfigurationList; buildConfigurations = {sequence(target_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
target = obj("target", f'isa = PBXNativeTarget; buildConfigurationList = {target_config_list}; buildPhases = ({sources}, {frameworks}, {resources_id},); buildRules = (); dependencies = (); name = Hongguo; packageProductDependencies = ({core}, {playback},); productName = Hongguo; productReference = {app}; productType = "com.apple.product-type.application";')
project = obj("project", f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; TargetAttributes = {{ {target} = {{ CreatedOnToolsVersion = 16.0; }}; }}; }}; buildConfigurationList = {project_config_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_TW; hasScannedForEncodings = 0; knownRegions = (en, Base, zh_TW, zh_CN,); mainGroup = {group}; packageReferences = ({package},); productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},);')
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {project};\n}}\n")

scheme = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")
build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
entries = ET.SubElement(build, "BuildActionEntries")
entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES", buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
reference = dict(BuildableIdentifier="primary", BlueprintIdentifier=target, BuildableName="Hongguo.app", BlueprintName="Hongguo", ReferencedContainer="container:Hongguo.xcodeproj")
ET.SubElement(entry, "BuildableReference", **reference)
ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", shouldUseLaunchSchemeArgsEnv="YES")
launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", debugServiceExtension="internal", allowLocationSimulation="YES")
runnable = ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0")
ET.SubElement(runnable, "BuildableReference", **reference)
profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
ET.SubElement(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"), "BuildableReference", **reference)
ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
scheme_dir = PROJECT / "xcshareddata" / "xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
ET.indent(scheme)
ET.ElementTree(scheme).write(scheme_dir / "Hongguo.xcscheme", encoding="utf-8", xml_declaration=True)
print(f"Generated {PROJECT} ({len(source_ids)} Swift files)")
