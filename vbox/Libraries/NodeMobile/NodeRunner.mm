//
//  NodeRunner.mm
//  vbox
//
//  ObjC++ 桥接层 —— 连接 Swift 和 nodejs-mobile (NodeMobile.framework)
//  Node.js 引擎在独立后台线程运行（官方要求 2MB 栈空间）
//

#import "NodeRunner.h"
#import <NodeMobile/NodeMobile.h>
#import <string>
#import <pthread.h>

static BOOL _nodeEngineStarted = NO;

@implementation NodeRunner

+ (BOOL)isEngineStarted {
    return _nodeEngineStarted;
}

+ (void)markEngineStarted {
    _nodeEngineStarted = YES;
}

// node's libUV requires all arguments being on contiguous memory.
+ (void)startEngineWithArguments:(NSArray<NSString *> *)arguments {
    if (_nodeEngineStarted) {
        NSLog(@"[NodeBridge] ⚠️ Node 引擎已启动，忽略重复启动请求");
        return;
    }
    if (!arguments || arguments.count == 0) {
        NSLog(@"[NodeBridge] ❌ 启动参数为空");
        return;
    }

    int c_arguments_size = 0;
    // Compute byte size need for all arguments in contiguous memory.
    for (id argElement in arguments) {
        c_arguments_size += strlen([argElement UTF8String]);
        c_arguments_size++; // for '\0'
    }
    // Stores arguments in contiguous memory.
    char *args_buffer = (char *)calloc(c_arguments_size, sizeof(char));
    // argv to pass into node.
    char *argv[[arguments count]];
    // To iterate through the expected start position of each argument in args_buffer.
    char *current_args_position = args_buffer;
    // Argc
    int argument_count = 0;
    // Populate the args_buffer and argv.
    for (id argElement in arguments) {
        const char *current_argument = [argElement UTF8String];
        // Copy current argument to its expected position in args_buffer
        strncpy(current_args_position, current_argument, strlen(current_argument));
        // Save current argument start position in argv and increment argc.
        argv[argument_count] = current_args_position;
        argument_count++;
        // Increment to the next argument's expected position.
        current_args_position += strlen(current_args_position) + 1;
    }
    // Start node, with argc and argv.
    NSLog(@"[NodeBridge] 🚀 node_start 启动 (argc=%d, 入口=%@)", argument_count, arguments.count > 1 ? arguments[1] : @"(无)");
    _nodeEngineStarted = YES;
    node_start(argument_count, argv);
    free(args_buffer);
    NSLog(@"[NodeBridge] 🔚 node_start 返回（引擎已退出）");
}

@end
