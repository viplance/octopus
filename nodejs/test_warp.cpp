#include <CoreGraphics/CoreGraphics.h>
#include <iostream>
int main() {
    CGEventRef locEvent = CGEventCreate(NULL);
    CGPoint currentLoc = CGEventGetLocation(locEvent);
    CFRelease(locEvent);
    std::cout << currentLoc.x << ", " << currentLoc.y << std::endl;
    return 0;
}
