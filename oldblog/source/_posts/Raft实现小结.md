title: Raft实现小结
date: 2017-03-20 19:02:13
tags: [Raft, 分布式系统, 分布式一致性协议]
categories: [系统]
---


上一周花了大部分时间重新拾起了之前落下的MIT6.824 2016的分布式课程，实现和调试了下Raft协议，虽然Raft协议相对其他容错分布式一致性协议如Paxos/Multi-Paxos/VR/Zab等来说更容易理解，但是在实现和调试过程中也遇到不少细节问题。虽然论文中有伪代码似的协议描述，但是要把每一小部分逻辑组合起来放到正确的位置还是需要不少思考和踩坑的，这篇文章对此做一个小结。


----


### Raft实现
这里实现的主要是Raft基本的Leader Election和Log Replication部分，没有考虑Snapshot和Membership Reconfiguration的部分，因为前两者是后两者的实现基础，也是Raft协议的核心。MIT6.824 2016使用的是Go语言实现，一大好处是并发和异步处理非常直观简洁，不用自己去管理异步线程。

+ 宏观
    + 合理规划同步和异步执行的代码块，比如Heartbeat routine/向多个节点异步发送请求的routine
    + 注意加锁解锁，每个节点的heartbeat routine/请求返回/接收请求都可能改变Raft结构的状态数据，尤其注意不要带锁发请求，很容易和另一个同时带锁发请求的节点死锁
    + 理清以下几块的大体逻辑
        + 公共部分的逻辑
            + 发现小的term丢弃
            + 发现大的term，跟新自身term，转换为Follower，重置votedFor
            + 修改term/votedFor/log之后需要持久化
        + Leader/Follower/Candidate的Heartbeat routine逻辑
        + Leader Election
            + 发送RequestVote并处理返回，成为leader后的逻辑(nop log replication)
            + 接收到RequestVote的逻辑，如何投票(Leader Election Restriction)
        + Log Replication        
            + 发送AppendEntries并处理返回(consistency check and repair)，达成一致后的逻辑(更新commitIndex/nextIndex/matchIndex， apply log)
            + 接收到AppendEntries的逻辑(consistency check and repair, 更新commitIndex，apply log)

+ 细节
    + Leader Election
        + timeout的随机性
        + timeout的范围，必须远大于rpc请求的平均时间，不然可能很久都选不出主，通常rpc请求在ms级别，所以可设置150~300ms
        + 选主请求发送结束后，由于有可能在选主请求(RequestVote)的返回或者别的节点的选主请求中发现较大的term，而被重置为Follower，这时即使投票数超过半数也应该放弃成为Leader，因为当前选主请求的term已经过时，成为Leader可能导致在新的term中出现两个Leader.(注意这点是由于发送请求是异步的，同步请求发现较大的term后可直接修改状态返回)
        + 每次发现较大的term时，自身重置为Follower，更新term的同时，需要重置votedFor，以便在新的term中可以参与投票
        + 每次选主成功后，发送一条nop的日志复制请求，让Leader提交所有之前应该提交的日志，从而让Leader的状态机为最新，这样为读请求提供linearializability，不会返回stale data
    + Log Replication
        + Leader更新commitIndex时，需要严格按照论文上的限制条件(使用matchIndex)，不能提交以前term的日志
        + 对于同一term同一log index的日志复制，如果失败，应该无限重试，直到成功或者自身不再是Leader，因为我们需要保证在同一term同一log index下有唯一的一条日志cmd，如果不无限重试，有可能会导致以下的问题
            + 五个节点(0, 1, 2, 3, 4), node 0为leader，复制一条Term n, LogIndex m, Cmd cmd1的日志
            + node 1收到cmd1的日志请求，node 2, 3, 4未收到
            + 如果node 0不无限重试而返回，此时另一个cmd2的日志复制请求到达，leader 0使用同一个Term和LogIndex发送请求
            + node 2, 3, 4收到cmd2的请求，node 1未收到
            + node 1通过election成为新的leader(RequestVote的检查会通过，因为具有相同的Term和LogIndex)
            + node 1发送nop提交之前的日志，cmd1被applied(consistency check会通过，因为PrevLogTerm和PrevLogIndex相同)
            + cmd2则被node 2, 3, 4 applied
            + cmd1和cmd2发生了不一致


+ 测试和其他一些问题
    + 测试过程中发现MIT6.824测试有两处小问题
        + 一个是TestReElection中隔离leader1，重连leader1后需要睡眠至少一个心跳周期，让leader1接收到leader1的心跳而转换为follower
        + 另一个是cfg.one中提交一个日志后需要检查所有参与节点applied日志后的结果，所以需要leader和所有follower尽早applied日志，但是follower总是滞后于leader至少一个心跳周期或者一次AppendEntries请求的，所以这个检查有时会失败，从而导致测试失败。
    + Start异步执行的问题?
        + 由于测试代码直接阻塞调用Start，需要获取Start返回的Term/Index等，当日志复制请求失败时，Start会无限重试，从而阻塞测试代码，而无法重新加入节点，导致整个测试阻塞，所以Start的实现需要支持异步
        + 如果在单独的goroutine中执行Start的逻辑，让Start异步并发执行，log index的获取是序列化的(Raft需要保证前面所有的日志提交后才能提交本条日志)，且log index较大的由于较小log index的consistency check失败而阻塞，仍然需要等待前面较小log index的日志达成多数派，所以本质上后面的请求需要等待前面的请求完成并持久化日志然后再拿下一个log index，所以还是序列化的。只是不会阻塞Start调用。
    + 一些优化点在保证基本协议正确性的前提下如何实现?
        + 锁的优化
        + pipeline
        + batch
    + 客户端交互，保证exactly once语义



----


### 总结

+ 一个工程级别的分布式一致性协议实现并不容易，要注意的细节很多，不仅要保证正确地实现协议，还要考虑优化点，在优化整个系统的性能时保证系统的正确性。
+ 分布式系统尤其是像分布式一致性协议这样的复杂系统需要大量的测试来保证系统的正确性，算法本身简洁的描述忽略了非常多实际工程中会遇到的各种fault，在工程实现之后很难保证其正确性，有些case需要经历多次状态转换才能发现失败原因。
+ 大致实现了Raft之后，再回过头去看Paxos/Multi-Paxos，会更明白Raft为了简单做的trade-off
    + 保证协议safety性质的前提下，通过增加以下三个条件来简化Leader恢复或者说View Change过程中的状态恢复，保证日志从Leader上单向流动到Follower(而这个过程又可以合并到AppendEntries日志复制的逻辑中，即consistency check)，这个过程往往是关键和最复杂的步骤。
        + 选主的时候满足发请求的节点和被请求的节点日志至少一样新，保证选主成功后Leader上的日志最新
        + 日志必须顺序提交(对数据库事务日志来说可能并不友好)
        + 新选出的Leader不能直接提交以前Term的日志，需要写入一条当前Term的日志后才能提交之前Term的日志
+ 最后放上简单的代码供参考:-), [Raft](https://github.com/feilengcui008/moocs/blob/master/mit_6.824/2016/src/raft/raft.concurrent.go)
