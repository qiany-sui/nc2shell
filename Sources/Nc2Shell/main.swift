import Foundation

// 必须先分流，避免认证子进程创建窗口、读取连接配置或初始化 AppModel。
_ = SSHAskpass.runIfRequested()
Nc2ShellApp.main()
