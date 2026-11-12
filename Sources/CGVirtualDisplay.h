// Declarations for CoreGraphics' private virtual-display classes.
//
// Apple does not publish this API. These are the classes BetterDisplay, DeskPad
// and Chromium's display tests rely on; the shapes below follow the interfaces
// Chromium generated from the CoreGraphics binary
// (ui/display/mac/test/virtual_display_util_mac.mm).
// A future macOS release could change or remove them.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// One resolution the display offers. Width and height are in points.
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (strong, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
/// 1 makes macOS render each mode at 2x (Retina), 0 at 1x.
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (strong, nonatomic, nullable) dispatch_queue_t queue;
@property (strong, nonatomic) NSString *name;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
/// Largest framebuffer the display will ever need, in pixels.
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings NS_SWIFT_NAME(apply(_:));
@end

NS_ASSUME_NONNULL_END
