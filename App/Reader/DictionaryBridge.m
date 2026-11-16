#import "DictionaryBridge.h"
#import <CoreServices/CoreServices.h>

NSString *ReaderDictionaryDefinition(NSString *term) {
    if (term.length == 0) {
        return nil;
    }
    CFStringRef definition = DCSCopyTextDefinition(NULL, (__bridge CFStringRef)term, CFRangeMake(0, (CFIndex)term.length));
    if (definition == NULL) {
        return nil;
    }
    return (__bridge_transfer NSString *)definition;
}
