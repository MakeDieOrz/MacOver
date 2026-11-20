import Foundation
import XCTest

final class AKPluginLoaderTests: XCTestCase {
    private var tempDir: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AKPluginLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func buildBundle(
        named bundleName: String,
        executableName: String?,
        principalClassName: String?,
        objcSource: String?
    ) throws -> URL {
        let dir = try XCTUnwrap(tempDir)
        let bundleURL = dir.appendingPathComponent("\(bundleName).bundle", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        if let executableName, let objcSource {
            let srcURL = dir.appendingPathComponent("\(bundleName).m")
            try objcSource.write(to: srcURL, atomically: true, encoding: .utf8)
            let execURL = macOSURL.appendingPathComponent(executableName)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            process.arguments = [
                "-arch", "arm64",
                "-bundle",
                "-fobjc-arc",
                "-framework", "Foundation",
                "-framework", "CoreGraphics",
                srcURL.path,
                "-o", execURL.path
            ]
            let errPipe = Pipe()
            process.standardError = errPipe
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? ""
                XCTFail("clang failed (\(process.terminationStatus)): \(errMsg)")
            }
        }

        var plist: [String: Any] = [
            "CFBundleIdentifier": "io.playcover.test.\(bundleName)",
            "CFBundlePackageType": "BNDL"
        ]
        if let executableName {
            plist["CFBundleExecutable"] = executableName
        }
        if let principalClassName {
            plist["NSPrincipalClass"] = principalClassName
        }
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return bundleURL
    }

    func testLoadPluginValidNonConformingMissingPrincipalAndMissingBundle() throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let goodClass = "GoodAKPlugin_\(suffix)"
        let badClass = "BadAKPlugin_\(suffix)"

        let goodSource = """
        #import <Foundation/Foundation.h>
        @protocol PTAKInterfacePlugin <NSObject>
        - (instancetype)init;
        @property (nonatomic, readonly) NSInteger screenCount;
        @property (nonatomic, readonly) CGPoint mousePoint;
        @property (nonatomic, readonly) CGRect windowFrame;
        @property (nonatomic, readonly) CGRect mainScreenFrame;
        @property (nonatomic, readonly) BOOL isMainScreenEqualToFirst;
        @property (nonatomic, readonly) BOOL isFullscreen;
        @property (nonatomic, readonly) BOOL cmdPressed;
        - (void)hideCursor;
        - (void)hideCursorMove;
        - (void)warpCursor;
        - (void)unhideCursor;
        - (void)terminateApplication;
        - (void)setupKeyboardWithKeyboard:(BOOL (^)(uint16_t, BOOL, BOOL, BOOL))keyboard swapMode:(BOOL (^)(void))swapMode;
        - (void)setupMouseMoved:(BOOL (^)(CGFloat, CGFloat))mouseMoved;
        - (void)setupMouseButtonWithLeft:(BOOL)left right:(BOOL)right :(BOOL (^)(NSInteger, BOOL))consumed;
        - (void)setupScrollWheel:(BOOL (^)(CGFloat, CGFloat))onMoved;
        - (nullable NSURL *)urlForApplicationWithBundleIdentifier:(NSString *)value;
        - (void)setMenuBarVisible:(BOOL)value;
        @end

        @interface \(goodClass) : NSObject <PTAKInterfacePlugin>
        @end
        @implementation \(goodClass)
        - (instancetype)init { return [super init]; }
        - (NSInteger)screenCount { return 2; }
        - (CGPoint)mousePoint { return CGPointMake(12, 34); }
        - (CGRect)windowFrame { return CGRectMake(0, 0, 800, 600); }
        - (CGRect)mainScreenFrame { return CGRectMake(0, 0, 1920, 1080); }
        - (BOOL)isMainScreenEqualToFirst { return YES; }
        - (BOOL)isFullscreen { return NO; }
        - (BOOL)cmdPressed { return NO; }
        - (void)hideCursor {}
        - (void)hideCursorMove {}
        - (void)warpCursor {}
        - (void)unhideCursor {}
        - (void)terminateApplication {}
        - (void)setupKeyboardWithKeyboard:(BOOL (^)(uint16_t, BOOL, BOOL, BOOL))keyboard swapMode:(BOOL (^)(void))swapMode {}
        - (void)setupMouseMoved:(BOOL (^)(CGFloat, CGFloat))mouseMoved {}
        - (void)setupMouseButtonWithLeft:(BOOL)left right:(BOOL)right :(BOOL (^)(NSInteger, BOOL))consumed {}
        - (void)setupScrollWheel:(BOOL (^)(CGFloat, CGFloat))onMoved {}
        - (nullable NSURL *)urlForApplicationWithBundleIdentifier:(NSString *)value { return [NSURL fileURLWithPath:@"/Applications/Test.app"]; }
        - (void)setMenuBarVisible:(BOOL)value {}
        @end
        """

        let badSource = """
        #import <Foundation/Foundation.h>
        @interface \(badClass) : NSObject
        @end
        @implementation \(badClass)
        @end
        """

        let dir = try XCTUnwrap(tempDir)
        let missingURL = dir.appendingPathComponent("Missing.bundle")
        let missingPrincipalURL = try buildBundle(
            named: "NoPrincipal",
            executableName: nil,
            principalClassName: nil,
            objcSource: nil
        )
        let nonConformingURL = try buildBundle(
            named: "NonConforming",
            executableName: "NonConformingExec",
            principalClassName: badClass,
            objcSource: badSource
        )
        let validURL = try buildBundle(
            named: "ValidAK",
            executableName: "ValidAKExec",
            principalClassName: goodClass,
            objcSource: goodSource
        )

        XCTAssertNil(AKInterface.loadPlugin(from: [nil, missingURL]))
        XCTAssertNil(AKInterface.loadPlugin(from: [missingPrincipalURL]))
        XCTAssertNil(AKInterface.loadPlugin(from: [nonConformingURL]))

        let loaded = try XCTUnwrap(AKInterface.loadPlugin(from: [missingURL, nonConformingURL, validURL]))
        XCTAssertEqual(loaded.screenCount, 2)
        XCTAssertEqual(loaded.mousePoint, CGPoint(x: 12, y: 34))
        XCTAssertEqual(loaded.windowFrame, CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(loaded.isMainScreenEqualToFirst)
        XCTAssertFalse(loaded.isFullscreen)
        XCTAssertEqual(loaded.urlForApplicationWithBundleIdentifier("com.test")?.path, "/Applications/Test.app")

        AKInterface.initialize()
        XCTAssertNil(AKInterface.shared)
    }

    func testSequoiaOptionalGeometryAndOrientationBridgeMethods() throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let seqClass = "SequoiaAKPlugin_\(suffix)"
        let source = """
        #import <Foundation/Foundation.h>
        @protocol PTAKInterfacePlugin <NSObject>
        - (instancetype)init;
        @property (nonatomic, readonly) NSInteger screenCount;
        @property (nonatomic, readonly) CGPoint mousePoint;
        @property (nonatomic, readonly) CGRect windowFrame;
        @property (nonatomic, readonly) CGRect mainScreenFrame;
        @property (nonatomic, readonly) BOOL isMainScreenEqualToFirst;
        @property (nonatomic, readonly) BOOL isFullscreen;
        @property (nonatomic, readonly) BOOL cmdPressed;
        - (void)hideCursor;
        - (void)hideCursorMove;
        - (void)warpCursor;
        - (void)unhideCursor;
        - (void)terminateApplication;
        - (void)setupKeyboardWithKeyboard:(BOOL (^)(uint16_t, BOOL, BOOL, BOOL))keyboard swapMode:(BOOL (^)(void))swapMode;
        - (void)setupMouseMoved:(BOOL (^)(CGFloat, CGFloat))mouseMoved;
        - (void)setupMouseButtonWithLeft:(BOOL)left right:(BOOL)right :(BOOL (^)(NSInteger, BOOL))consumed;
        - (void)setupScrollWheel:(BOOL (^)(CGFloat, CGFloat))onMoved;
        - (nullable NSURL *)urlForApplicationWithBundleIdentifier:(NSString *)value;
        - (void)setMenuBarVisible:(BOOL)value;
        @optional
        @property (nonatomic, readonly) BOOL isSequoiaOrNewer;
        - (void)setWindowContentSize:(CGSize)size;
        - (void)setWindowAspectRatio:(CGSize)ratio;
        - (void)clearWindowAspectRatio;
        - (void)setWindowOrientationWithPortrait:(BOOL)portrait targetSize:(CGSize)targetSize;
        - (void)setupWindowGeometryChanged:(void (^)(CGRect))callback;
        @end

        @interface \(seqClass) : NSObject <PTAKInterfacePlugin>
        @property (nonatomic, assign) CGRect currentFrame;
        @property (nonatomic, copy) void (^geometryCallback)(CGRect);
        @end
        @implementation \(seqClass)
        - (instancetype)init {
            if ((self = [super init])) { _currentFrame = CGRectMake(0, 0, 800, 600); }
            return self;
        }
        - (NSInteger)screenCount { return 1; }
        - (CGPoint)mousePoint { return CGPointMake(0, 0); }
        - (CGRect)windowFrame { return _currentFrame; }
        - (CGRect)mainScreenFrame { return CGRectMake(0, 0, 1920, 1080); }
        - (BOOL)isMainScreenEqualToFirst { return YES; }
        - (BOOL)isFullscreen { return NO; }
        - (BOOL)cmdPressed { return NO; }
        - (BOOL)isSequoiaOrNewer { return YES; }
        - (void)hideCursor {}
        - (void)hideCursorMove {}
        - (void)warpCursor {}
        - (void)unhideCursor {}
        - (void)terminateApplication {}
        - (void)setupKeyboardWithKeyboard:(BOOL (^)(uint16_t, BOOL, BOOL, BOOL))keyboard swapMode:(BOOL (^)(void))swapMode {}
        - (void)setupMouseMoved:(BOOL (^)(CGFloat, CGFloat))mouseMoved {}
        - (void)setupMouseButtonWithLeft:(BOOL)left right:(BOOL)right :(BOOL (^)(NSInteger, BOOL))consumed {}
        - (void)setupScrollWheel:(BOOL (^)(CGFloat, CGFloat))onMoved {}
        - (nullable NSURL *)urlForApplicationWithBundleIdentifier:(NSString *)value { return nil; }
        - (void)setMenuBarVisible:(BOOL)value {}
        - (void)setupWindowGeometryChanged:(void (^)(CGRect))callback { _geometryCallback = [callback copy]; }
        - (void)setWindowContentSize:(CGSize)size {
            _currentFrame.size = size;
            if (_geometryCallback) { _geometryCallback(_currentFrame); }
        }
        - (void)setWindowAspectRatio:(CGSize)ratio { (void)ratio; }
        - (void)clearWindowAspectRatio {}
        - (void)setWindowOrientationWithPortrait:(BOOL)portrait targetSize:(CGSize)targetSize {
            CGFloat s = MIN(targetSize.width, targetSize.height);
            CGFloat l = MAX(targetSize.width, targetSize.height);
            _currentFrame.size = portrait ? CGSizeMake(s, l) : CGSizeMake(l, s);
            if (_geometryCallback) { _geometryCallback(_currentFrame); }
        }
        @end
        """

        let seqURL = try buildBundle(
            named: "SequoiaAK",
            executableName: "SequoiaAKExec",
            principalClassName: seqClass,
            objcSource: source
        )
        let loaded = try XCTUnwrap(AKInterface.loadPlugin(from: [seqURL]))
        XCTAssertEqual(loaded.isSequoiaOrNewer, true)

        var observedFrames: [CGRect] = []
        loaded.setupWindowGeometryChanged? { observedFrames.append($0) }
        loaded.setWindowContentSize?(CGSize(width: 1280, height: 720))
        XCTAssertEqual(loaded.windowFrame.size, CGSize(width: 1280, height: 720))
        loaded.setWindowOrientation?(portrait: true, targetSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(loaded.windowFrame.size, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(observedFrames.count, 2)
    }
}
