#ifndef SECOND_DISPLAY_PRIVATE_API_SHIM_H
#define SECOND_DISPLAY_PRIVATE_API_SHIM_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t SDVDClassRoleMask;
enum {
    SDVDClassRoleDisplay = 1u << 0,
    SDVDClassRoleDescriptor = 1u << 1,
    SDVDClassRoleSettings = 1u << 2,
    SDVDClassRoleMode = 1u << 3,
};

typedef uint32_t SDVDSelectorRoleMask;
enum {
    SDVDSelectorRoleDisplayInitializer = 1u << 0,
    SDVDSelectorRoleApplySettings = 1u << 1,
    SDVDSelectorRoleDisplayIdentifier = 1u << 2,
    SDVDSelectorRoleModeInitializer = 1u << 3,
};

typedef struct {
    SDVDClassRoleMask missingClassRoles;
    SDVDSelectorRoleMask missingSelectorRoles;
} SDVDCapabilityProbeResult;

typedef enum : uint32_t {
    SDVDCreateStatusSuccess = 0,
    SDVDCreateStatusCapabilityMissing = 1,
    SDVDCreateStatusInvalidArgument = 2,
    SDVDCreateStatusAllocationFailed = 3,
    SDVDCreateStatusApplyFailed = 4,
} SDVDCreateStatus;

typedef struct {
    const char *name;
    uint32_t vendorID;
    uint32_t productID;
    uint32_t serialNumber;
    uint32_t framebufferWidth;
    uint32_t framebufferHeight;
    uint32_t logicalWidth;
    uint32_t logicalHeight;
    double physicalWidthMM;
    double physicalHeightMM;
    double refreshRate;
} SDVDCreateConfiguration;

typedef void (*SDVDTerminationCallback)(CGDirectDisplayID displayID, void *context);

typedef struct {
    void *token;
    CGDirectDisplayID displayID;
    SDVDCreateStatus status;
} SDVDCreateResult;

SDVDCapabilityProbeResult SDVDProbeCapabilities(void);

SDVDCreateResult SDVDCreateDisplay(
    SDVDCreateConfiguration configuration,
    SDVDTerminationCallback callback,
    void *context
);

void SDVDDestroyDisplay(void *token);

#ifdef __cplusplus
}
#endif

#endif

