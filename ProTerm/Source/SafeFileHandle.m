#import <Foundation/Foundation.h>

NSData* _Nullable safeReadAvailableData(NSFileHandle* handle) {
    @try {
        // availableData should only be called when data is available
        // If it returns empty, that means EOF, so return empty data (not nil)
        // The Swift code will handle empty data appropriately
        NSData* data = [handle availableData];
        return data;
    }
    @catch (NSException* exception) {
        // File descriptor is closed or invalid - return nil to indicate error
        return nil;
    }
}

