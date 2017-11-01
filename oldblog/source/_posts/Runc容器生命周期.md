title: Runc容器生命周期
date: 2016-11-30 17:48:20
tags: [Docker, Runc]
categories: [系统, 容器技术]
---

容器的生命周期涉及到内部的程序实现和面向用户的命令行界面，runc内部容器状态转换操作、runc命令的参数定义的操作、docker client定义的容器操作是不同的，比如对于docker client的create来说，
语义和runc就完全不同，这一篇文章分析runc的容器生命周期的抽象、内部实现以及状态转换图。理解了runc的容器状态转换再对比理解docker client提供的容器操作命令的语义会更容易些。


----


#### 容器生命周期相关接口
+ 最基本的required的接口
    + Start: 初始化容器环境并启动一个init进程，或者加入已有容器的namespace并启动一个setns进程；执行postStart hook; 阻塞在init管道的写端，用户发信号替换执行真正的命令
    + Exec: 读init管道，通知init进程或者setns进程继续往下执行
    + Run: Start + Exec的组合
    + Signal: 向容器内init进程发信号
    + Destroy: 杀掉cgroups中的进程，删除cgroups对应的path，运行postStop的hook
    + 其他
        + Set: 更新容器的配置信息，比如修改cgroups resize等
        + Config: 获取容器的配置信息
        + State: 获取容器的状态信息
        + Status: 获取容器的当前运行状态: created、running、pausing、paused、stopped
        + Processes: 返回容器内所有进程的列表
        + Stats: 容器内的cgroups统计信息
  + 对于linux容器定义并实现了特有的功能接口
      + Pause: free容器中的所有进程
      + Resume: thaw容器内的所有进程
      + Checkpoint: criu checkpoint
      + Restore: criu restore


----


#### 接口在内部的实现
+ 对于Start/Run/Exec的接口是作为不同os环境下的标准接口对开发者暴露，接口在内部的实现有很多重复的部分可以统一，因此内部的接口实际上更简洁，这里以linux容器为例说明
    + 对于Start/Run/Exec在内部实现实际上只用到下面两个函数，通过传入flag(容器是否处于stopped状态)区分是创建容器的init进程还是创建进程的init进程
        + start: 创建init进程，如果status == stopped，则创建并执行newInitProcess，否则创建并执行newSetnsProcess，等待用户发送执行信号(等在管道写端上)，用用户的命令替换掉
        + exec: 读管道，发送执行信号
    + Start直接使用start
    + Run实际先使用start(doInit = true)，然后exec
    + Exec实际先使用start(doInit = false), 然后exec


----


#### 对用户暴露的命令行参数与容器接口的对应关系，以linux容器为例
+ create -> Start(doInit = true)
+ start -> Exec 
+ run -> Run(doInit = true)
+ exec -> Run(doInit = false)
+ kill -> Signal 
+ delete -> Signal and Destroy
+ update -> Set 
+ state -> State 
+ events -> Stats 
+ ps -> Processes
+ list
+ linux specific
    + pause -> Pause 
    + resume -> Resume
    + checkpoint -> Checkpoint 
    + restore -> Restore 


----


#### runc命令行的动作序列对容器状态机的影响
+ 对于一个容器的生命周期来说，稳定状态有4个: stopped、created、running、paused
+ 注意下面状态转换图中的动作是runc命令行参数动作，不是容器的接口动作，这里没考虑checkpoint相关的restore状态
    + ![Runc容器状态机](/images/runc.png)

