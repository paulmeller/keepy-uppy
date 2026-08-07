#ifndef PowerSPI_h
#define PowerSPI_h

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOReturn.h>

extern IOReturn IOPMSetSystemPowerSetting(CFStringRef key, CFTypeRef value);
extern CFDictionaryRef IOPMCopySystemPowerSettings(void);

#endif /* PowerSPI_h */
