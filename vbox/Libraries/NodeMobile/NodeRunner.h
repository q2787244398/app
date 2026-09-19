//
//  NodeRunner.h
//  vbox
//
//  ObjC 桥接层 —— 连接 Swift 和 nodejs-mobile (NodeMobile.framework)
//  负责在独立后台线程启动 Node.js 常驻引擎（单实例，App 生命周期内只启动一次）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NodeRunner : NSObject

/// 在独立线程启动 Node.js 引擎（node_start）
/// @param arguments Node 启动参数，首个元素为可执行名（如 "node"），
///                 第二个为入口 JS 绝对路径（main.js）
/// 注意：nodejs-mobile 运行时单实例且不可重启，整个 App 生命周期只调用一次
+ (void)startEngineWithArguments:(NSArray<NSString *> *)arguments;

/// 检查 Node 引擎线程是否已启动
+ (BOOL)isEngineStarted;

/// 记录启动状态（供 Swift 侧查询）
+ (void)markEngineStarted;

@end

NS_ASSUME_NONNULL_END
