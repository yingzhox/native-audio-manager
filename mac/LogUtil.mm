#import "LogUtil.h"

void Log(const std::string& message, const std::string& level) {
    // Format the message
    NSString* formattedMessage = [NSString stringWithFormat:@"[AudioManager] [%@] \033[38;5;141m%@\033[0m", 
                                 [NSString stringWithUTF8String:level.c_str()],
                                 [NSString stringWithUTF8String:message.c_str()]];
    
    // Log to system log, it also prints to console
    NSLog(@"%@", formattedMessage);
}
