title: Paper Reading - In Search of an Understandable Consensus Algorithm
date: 2017-03-19   09:15:32
tags: [Raft, 容错分布式一致性协议, Paper]
categories: [系统, 分布式系统]
---

#### 0 Abstract

> In order to enhance understandability, Raft separates the key elements of consensus, such as leader election, log replication, and safety, and it enforces a stronger degree of coherency to reduce the number of states that must be considered

Raft强化Leader的作用，明确划分了协议各个阶段(leader election, log replication)的边界，并且让leader election中的一部分重要内容-新leader的状态恢复变得很直观简单，并且和普通的日志复制请求与心跳请求整合到同一个RPC。这在后面的分析会看到。


----


#### 1 Introduction

> Strong leader: Raft uses a stronger form of leader- ship than other consensus algorithms. For example, log entries only flow fromthe leader to other servers. This simplifies themanagement of the replicated log and makes Raft easier to understand

Raft在选主的时候会添加额外的限制条件，要求新选出的主一定具有最新的日志，这样无论是正常的log replication，还是leader election的状态恢复，日志都是单向流动到follower。这大大简化了恢复过程。

> Leader election: Raft uses randomized timers to elect leaders...

使用随机timeout的方式来触发选主。

> Membership changes: Raft’s mechanism for changing the set of servers in the cluster uses a new joint consensus approach where the majorities of two different configurations overlap during transi-tions...

成员组变更使用joint-consensus，也是两阶段形式。这里通过限制每次变更的server数量到一个，貌似可以做一些简化(具体参考下[etcd的设计和实现](https://coreos.com/etcd/docs/latest/op-guide/runtime-reconf-design.html))



----


#### 2 Replicated state machines

> Replicated state machines are typically implemented using a replicated log, as shown in Figure 1. Each server stores a log containing a series of commands, which its state machine executes in order...

> Keeping the replicated log consistent is the job of the consensus algorithm.

一致性协议的通常用法是作为复制状态机的日志复制模块，日志基本上是状态机一致性和持久性的基石，在计算机的系统领域有着及其重要的作用，可参考这篇很棒的文章-[The Log: What every software engineer should know about real-time data's unifying abstraction](https://engineering.linkedin.com/distributed-systems/log-what-every-software-engineer-should-know-about-real-time-datas-unifying)



----



#### 3 Whats's wrong with Paxos?

> Paxos’ opaqueness derives from its choice of the single-decree subset as its foundation. Single-decree Paxos is dense and subtle ... The composition rules for multi- Paxos add significant additional complexity and subtlety

Basic Paxos本身面向并发决议的场景，多个参与者可以同时提出决议，且Basic Paxos解决的是对单个值达成决议，实际应用中往往需要对多个值达成决议，就需要组合多轮Basic Paxos，而基于Basic Paxos的Multi-Paxos并没有比较好地在论文中描述如何组合多轮Basic Paxos，实现起来有很多细节问题。但是，面向单个值的设计也是Basic Paxos和Multi-Paxos的优势，对于每条日志可以单独提交，而不用像raft需要等待前面所有日志提交，这在后面Raft的详细描述中可看到。



----



#### 4 Designing for understandability

> in Raft we separated leader election, log replication, safety, andmembership changes.

一个是良好的模块划分，选主/日志复制/成员组变更。

> logs are not allowed to have holes, and Raft limits the ways in which logs can become inconsistent with each other.

Raft不允许日志有空洞，这大大简化了其leader election后状态恢复的过程，但是同时也限制了其日志只能顺序提交。



----



#### 5.1 Raft basics

> At any given time each server is in one of three states: leader, follower, or candidate

节点三种角色：leader/follower/candidate。follower不会主动发RPC请求，leader发送AppendEntries的日志复制和心跳请求，candidate发送RequestVote的选主请求。


#### 5.2 Leader election

> To begin an election, a follower increments its current term and transitions to candidate state

leader的心跳超时，转换为candidate，等待随机的timeout，增加自身的term，发起选主请求。得到多数投票则成功，后续会看到选主投票时会加上限制条件。选主成功后，复制一条nop的日志，让之前term的日志全部提交，一遍读请求能读到最新的数据。


#### 5.3 Log replication

> If followers crash or run slowly, or if network packets are lost, the leader retries Append- Entries RPCs indefinitely (even after it has responded to the client) until all followers eventually store all log en- tries

这里的重试应该是指consistency check中的日志恢复，只要某个follower没有恢复到最新日志，leader就持续向该follower发送请求。而不是说在发送AppendEntries时如果遇到请求失败无限重试，这里如果达到多数派后应该返回成功，不要阻塞下一次请求。但是，如果没有达成多数派，这条log index位置初应该无限重试，不然会有正确性问题。

> The leader keeps track of the highest index it knows to be committed, and it includes that index in future AppendEntries RPCs (including heartbeats) so that the other servers eventually find out

注意leader更新commitIndex的时候需要借助matchIndex，严格按照图2的规则更新，避免提交之前term的日志。

> The first property follows from the fact that a leader creates atmost one entrywith a given log index in a given term

这个性质需要无限重试来保证，对于某个log index，如果没达成决议，则需要拿着相同的cmd无限重试，直到成功或者自己不在是leader。这样能保证在一个term和一个index log下不会存在两个不同的cmd被提交。否则如果不无限重试，可以构造一种状态转换，违背这个性质。

> the leader includes the index and term of the entry in its log that immediately precedes the new entries.

每次AppendEntries请求的prevLogTerm和prevLogIndex可以通过nextIndex数组来获得

> With thismechanism, a leader does not need to take any special actions to restore log consistencywhen it comes to power

这一点比较巧妙，把一致性协议中或者说其他主备系统中最复杂的一步leader状态恢复，融入进了日志复制和心跳的rpc请求中，大大简化了实现。


#### 5.4 Safety

> The restriction ensures that the leader for any given term con- tains all of the entries committed in previous terms (the Leader Completeness Property from Figure 3)

Leader Completeness Property保证正确性。保证Leader Completeness Property有两点需要注意: (1) 选主的限制条件 (2) 新leader不能提交之前term的日志。


#### 5.4.1 Election restriction

> The RequestVote RPC implements this restriction: the RPC includes information about the candidate’s log, and the voter denies its vote if its own log is more up-to-date than that of the candidate

如果请求者的term不低于自己，且日志不必自己旧，则投票。这样由于日志复制的多数派以及选主的多数派限制，新选出的leader一定有最新的日志。


#### 5.4.2 Committing entries from previous terms

> Raft never commits log entries from previous terms by count- ing replicas

新选出的leader恢复状态时，永远不要直接提交之前term的日志，需要在新term的第一条日志达成决议后，让consistency check的过程来提交之前term的日志。


#### 5.6 Timing and availability

> broadcastTime≪electionTimeout≪MTBF

尤其注意RPC请求的时间一定要远小于election timeout，否则会很久选不出主。



----



#### 6 Cluster membership changes

> The leader first creates the Cold,new configuration entry in its log and commits it to Cold,new (a majority of Cold and a majority of Cnew). Then it creates the Cnew entry and commits it to a majority of Cnew. There is no point in time in which Cold and Cnew can both make decisions independently

Cold,new被apply的的时候需要做两件事情，一件是向joint cluster发送Cnew并达成决议，在Cnew被apply之前，所有的log replication请求需要对old cluster和new cluster都达成决议，当Cnew被提交时，更改整个集群的peers

> The second issue is that the cluster leader may not be part of the new configuration. In this case, the leader steps down (returns to follower state) once it has committed the Cnew log entry. This means that there will be a period of time (while it is committingCnew)when the leader isman- aging a cluster that does not include itself; it replicates log entries but does not count itself in majorities.

Cnew日志的commitIndex还没有被心跳发送过去. 那这个地方在AppendEntries的多数派判断时，还需要判断自身是否在peers数组中，如果不在则本轮少一票.

> if a server receives a RequestVote RPC within the minimum election timeout of hearing from a cur- rent leader, it does not update its term or grant its vote

leader lease，表明leader很可能还未过期，此时先不投票。



----



#### 7 Log compaction

> Raft also includes a small amount of metadata in the snapshot: the last included index is the index of the last entry in the log that the snapshot replaces (the last en- try the state machine had applied), and the last included term is the term of this entry. These are preserved to sup- port the AppendEntries consistency check for the first log entry following the snapshot, since that entry needs a pre- vious log index and term. To enable cluster membership changes (Section 6), the snapshot also includes the latest configuration in the log as of last included index

snapshot请求中需要包含last included index和latest configuration

> Although servers normally take snapshots indepen-dently, the leader must occasionally send snapshots to followers that lag behind. This happens when the leader has already discarded the next log entry that it needs to send to a follower

leader需要发送状态机的snapshot数据给follower，不能靠follower自身的日志，因为有可能leader的日志还没完全复制到某个follower，此时leader发生了snapshot，把之前的log entry都丢掉了。




----



#### 8 Client interaction

> The solution is for clients to assign unique serial numbers to every command

如何处理客户端重试的重复请求

> First, a leader must have the latest information on which entries are committed. Raft handles this by having each leader commit a blank no-op entry into the log at the start of its term. 

> Second, a leadermust checkwhether it has been deposed before processing a read-only request. Raft handles this by having the leader exchange heartbeat messages with a majority of the cluster before responding to read-only requests. Alternatively, the leader could rely on the heartbeat mechanism to provide a form of lease.

如何保证读请求读到最新的数据: (1) 保证leader上的状态机的数据最新，每次选主后主动复制一条nop日志，提交之前term的所有日志，让状态机保持最新；(2) leader响应的时候保证自己是最新的leader，两个办法，一个是响应前发一条消息，如果得到多数派应答，则说明是最新，第二种是leader lease，leader如果在某个lease时间段内没有收到多数派的心跳回复就自动变为follower，每个leader刚选出时，等待lease的时间才开始处理请求。



----



#### 小结

保证协议safety性质的前提下，通过增加以下三个条件来简化Leader恢复或者说View Change过程中的状态恢复，保证日志从Leader上单向流动到Follower(而这个过程又可以合并到AppendEntries日志复制的逻辑中，即consistency check)，这个过程往往是关键和最复杂的步骤。
+ 选主的时候满足发请求的节点和被请求的节点日志至少一样新，保证选主成功后Leader上的日志最新
+ 日志必须顺序提交(对数据库事务日志来说可能并不友好)
+ 新选出的Leader不能直接提交以前Term的日志，需要写入一条当前Term的日志后才能提交之前Term的日志
