#import "PrivateAPIShim.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) uint32_t vendorID;
@property(nonatomic) uint32_t productID;
@property(nonatomic) uint32_t serialNum;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) uint32_t maxPixelsWide;
@property(nonatomic) uint32_t maxPixelsHigh;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) void (^terminationHandler)(CGVirtualDisplay *display);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) uint32_t hiDPI;
@property(nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end

@interface SDVDDisplayBox : NSObject
@property(nonatomic, strong) CGVirtualDisplay *display;
@end

@implementation SDVDDisplayBox
@end

static Class SDVDClass(NSString *name)
{
    return NSClassFromString(name);
}

static BOOL SDVDInstancesRespond(Class classObject, NSString *selectorName)
{
    if (classObject == Nil) {
        return NO;
    }
    return class_getInstanceMethod(classObject, NSSelectorFromString(selectorName)) != NULL;
}

SDVDCapabilityProbeResult SDVDProbeCapabilities(void)
{
    Class displayClass = SDVDClass(@"CGVirtualDisplay");
    Class descriptorClass = SDVDClass(@"CGVirtualDisplayDescriptor");
    Class settingsClass = SDVDClass(@"CGVirtualDisplaySettings");
    Class modeClass = SDVDClass(@"CGVirtualDisplayMode");

    SDVDClassRoleMask missingClasses = 0;
    if (displayClass == Nil) missingClasses |= SDVDClassRoleDisplay;
    if (descriptorClass == Nil) missingClasses |= SDVDClassRoleDescriptor;
    if (settingsClass == Nil) missingClasses |= SDVDClassRoleSettings;
    if (modeClass == Nil) missingClasses |= SDVDClassRoleMode;

    SDVDSelectorRoleMask missingSelectors = 0;
    if (!SDVDInstancesRespond(displayClass, @"initWithDescriptor:")) {
        missingSelectors |= SDVDSelectorRoleDisplayInitializer;
    }
    if (!SDVDInstancesRespond(displayClass, @"applySettings:")) {
        missingSelectors |= SDVDSelectorRoleApplySettings;
    }
    if (!SDVDInstancesRespond(displayClass, @"displayID")) {
        missingSelectors |= SDVDSelectorRoleDisplayIdentifier;
    }
    if (!SDVDInstancesRespond(modeClass, @"initWithWidth:height:refreshRate:")) {
        missingSelectors |= SDVDSelectorRoleModeInitializer;
    }

    return (SDVDCapabilityProbeResult) {
        .missingClassRoles = missingClasses,
        .missingSelectorRoles = missingSelectors,
    };
}

SDVDCreateResult SDVDCreateDisplay(
    SDVDCreateConfiguration configuration,
    SDVDTerminationCallback callback,
    void *context
)
{
    SDVDCapabilityProbeResult probe = SDVDProbeCapabilities();
    if (probe.missingClassRoles != 0 || probe.missingSelectorRoles != 0) {
        return (SDVDCreateResult) {
            .token = NULL,
            .displayID = kCGNullDirectDisplay,
            .status = SDVDCreateStatusCapabilityMissing,
        };
    }
    if (configuration.name == NULL || configuration.framebufferWidth == 0
        || configuration.framebufferHeight == 0 || configuration.logicalWidth == 0
        || configuration.logicalHeight == 0 || configuration.refreshRate <= 0) {
        return (SDVDCreateResult) {
            .token = NULL,
            .displayID = kCGNullDirectDisplay,
            .status = SDVDCreateStatusInvalidArgument,
        };
    }

    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
    if (descriptor == nil) {
        return (SDVDCreateResult) {
            .token = NULL,
            .displayID = kCGNullDirectDisplay,
            .status = SDVDCreateStatusAllocationFailed,
        };
    }
    descriptor.vendorID = configuration.vendorID;
    descriptor.productID = configuration.productID;
    descriptor.serialNum = configuration.serialNumber;
    descriptor.name = [NSString stringWithUTF8String:configuration.name];
    descriptor.maxPixelsWide = configuration.framebufferWidth;
    descriptor.maxPixelsHigh = configuration.framebufferHeight;
    descriptor.sizeInMillimeters = CGSizeMake(configuration.physicalWidthMM, configuration.physicalHeightMM);
    descriptor.queue = dispatch_get_main_queue();
    if (callback != NULL) {
        descriptor.terminationHandler = ^(CGVirtualDisplay *terminatedDisplay) {
            callback(terminatedDisplay.displayID, context);
        };
    }

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc]
        initWithWidth:configuration.logicalWidth
               height:configuration.logicalHeight
          refreshRate:configuration.refreshRate];
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    if (display == nil || mode == nil || settings == nil) {
        return (SDVDCreateResult) {
            .token = NULL,
            .displayID = kCGNullDirectDisplay,
            .status = SDVDCreateStatusAllocationFailed,
        };
    }
    settings.hiDPI = 1;
    settings.modes = @[mode];
    if (![display applySettings:settings]) {
        display = nil;
        return (SDVDCreateResult) {
            .token = NULL,
            .displayID = kCGNullDirectDisplay,
            .status = SDVDCreateStatusApplyFailed,
        };
    }

    SDVDDisplayBox *box = [[SDVDDisplayBox alloc] init];
    if (box == nil) {
        display = nil;
        return (SDVDCreateResult) {
            .token = NULL,
            .displayID = kCGNullDirectDisplay,
            .status = SDVDCreateStatusAllocationFailed,
        };
    }
    box.display = display;
    return (SDVDCreateResult) {
        .token = (__bridge_retained void *)box,
        .displayID = display.displayID,
        .status = SDVDCreateStatusSuccess,
    };
}

void SDVDDestroyDisplay(void *token)
{
    if (token == NULL) {
        return;
    }
    SDVDDisplayBox *box = (__bridge_transfer SDVDDisplayBox *)token;
    box.display = nil;
}

