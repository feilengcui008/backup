title: Paper Reading - Large-scale cluster management at Google with Borg
date: 2017-03-31 23:05:00
tags: [分布式资源管理与调度, 容器技术, Borg, Paper]
categories: [系统, 分布式系统]
---

#### 0. Abstract

> It achieves high utilization by combining admission control, efficient task-packing, over-commitment, and machine sharing with process-level performance isolation

最重要的三点：装箱与调度算法，资源的抢占/reclaim/over-commit，资源的隔离。



----



#### 2.1 The workload

> we classify higher-priority Borg jobs as “production” (prod) ones, and the rest as “non-production” (non-prod). Most long-running server jobs are prod; most batch jobs are non-prod......The discrepancies between allocation and usage will prove important in...

工作负载主要分为生产级别和非生产级别，通常分别对应在线任务(Service)和离线任务(Batch Job)，资源的分配和使用量之间的差值可以被充分利用，这点在后面resource reclaim与资源over-commit可以看到。


#### 2.2 Clusters and cells

> The machines in a cell belong to a single cluster...

通常基于多个数据中心的集群之上还可以构建一个更高层的管理平台，负责一些跨数据中心的策略相对简单的调度，比如k8s的federation。


#### 2.3 Jobs and tasks

> A Borg job’s properties include its name, owner, and the number of tasks it has

Job相当于一个Service或者Batch Job，task相当于Service或者Batch Job的每个实例，通常一个实例也对应着一个容器。实例之间大多数属性是相同的，比如资源需求，调度的机器过滤与容错策略等，少部分是唯一的，比如在Service或者Batch Job的索引等。


#### 2.4 Allocs

> A Borg alloc (short for allocation) is a reserved set of re- sources on a machine in which one or more tasks can be run...

类似k8s的pod，一个alloc对应一个容器，通常与一个task实例对应，但是一个alloc和一个容器可以跑多个task实例，这些实例之间是共享资源的，并且处于相同的资源namespace。

> An alloc set is like a job: it is a group of allocs that reserve resources on multiple machines...

容器组，通常对应一个Service或者Batch Job，容器组中容器的数量通常对应于task的数量。


#### 2.5 Priority, quota, and admission control

> Borg defines non-overlapping priority bands for dif- ferent uses, including (in decreasing-priority order): monitoring, production, batch, and best effort (also known as testing or free)...

优先级与抢占，这里定义的是Monitoring、Production，Batch，Best-effort的四种大的优先级band，每个band可有更细粒度的优先级。高优先级的Job可以抢占低优先级的Job，但是生产级别(Monitoring, Production)的Job之间不允许抢占。

> Quota-checking is part of admission control, not scheduling: jobs with insufficient quota are immediately rejected upon submission...

这里的配额是指各个产品线购买的资源预算，而不是指为Service或者Batch Job分配资源时的资源上限(limit)，在调度分配资源之前用配额来限制每个用户资源的可申请量。


#### 2.6 Naming and monitoring

> To enable this, Borg creates a stable “Borg name service” (BNS) name for each task that includes the cell name, job name, and task number...

服务发现，创建Service或者Batch Job的task实例时，注册task的唯一标识与对应ip和端口。




----



#### 3.2 Scheduling

> The schedul- ing algorithm has two parts: feasibility checking, to find ma- chines on which the task could run, and scoring, which picks one of the feasible machines...

这个地方的可行性检查感觉算在过滤器里比较好，打分的过程算作具体的装箱算法，因为可行性检查不需要比较细化的调优，而打分装箱的过程可以进行不同算法的实验与调优。

> task’s constraints and also have enough “available” resources – which includes resources assigned to lower-priority tasks that can be evicted...

高优先级的Job可以抢占低优先级的Job的资源，但是prod band优先级的Job之间不能互相抢占。

> we sometimes call this “worst fit”. The opposite end of the spectrum is “best fit”, which tries to fill machines as tightly as possible...

两种装箱的基本思路：worst fit，尽量先找空闲资源多的，best fit，尽量先填满某个机器。

> If the machine selected by the scoring phase doesn’t have enough available resources to fit the newtask, Borg preempts (kills) lower-priority tasks, from lowest to highest priority, until it does.We add the preempted tasks to the scheduler’s pending queue, rather than migrate or hibernate them...

在调度时，高优先级的Job是可以看到低优先级Job的资源的，实际分配下发任务时，可能需要抢占低优先级Job的资源，被kill掉的低优先级的task会重新调度。



----



#### 5.5 Resource reclamation

> This whole pro- cess is called resource reclamation. The estimate is called the task’s reservation, and is computed by the Borgmas- ter every few seconds, using fine-grained usage (resource- consumption) information captured by the Borglet. The ini- tial reservation is set equal to the resource request (the limit); after 300 s, to allow for startup transients, it decays slowly towards the actual usage plus a safety margin. The reserva- tion is rapidly increased if the usage exceeds it...

资源的reclaim，是在离线混布之后提高资源利用率的重要手段，可以使用best effort级别的Job。具体如何保证快速回收被临时占用的资源？

> for non-prod tasks, it uses the reservations of existing tasks so the new tasks can be scheduled into reclaimed resources

在调度的时候，non-prod优先级的Job是可以看到可以reclaimed的资源的，也就是，单机除去每个task实际请求的limit资源量，加上每个task被reclaimed的资源量，而每个task可以被reclaim的资源量计算方法是：limit - (一段时间内task实际使用的量+安全边界宽度)。显然，prod级别的Job在调度的时候必须使用limit来计算资源要求，不能用reclaim的资源。除了基本的高优先级Job抢占低优先级Job的资源，一个提高资源利用率的重要技术是资源的超发，prod级别的预留资源和实际使用的资源的差值可以用来跑低优先级的任务，best-effort的任务，对于在线Job来说不能被抢占，对于离线Job来说，只要整机的资源足够，且满足所有在线的Job后任然足够，则不会被抢占，对于best-effort来说，其看到的资源量实际上比一个离线的Job更多，可以被调度到一台可能资源被预留了百分之百的机器，使用此机器的reclaimed的资源，一旦prod需要重新使用这部分资源，best-effort的Job会被杀掉，所以best-effort的可用性较低。但是通过这种方式，大大提高了机器资源的利用率。



----



#### 6.1 Security isolation

> VMs and security sandboxing techniques are used to run external software by Google’s AppEngine (GAE) [38] and Google Compute Engine (GCE).We run each hostedVMin a KVM process [54] that runs as a Borg task...

google公有云也是使用borg来管理虚拟机？


#### 6.2 Performance isolation

> Even so, occasional low-level resource interference (e.g., memory bandwidth or L3 cache pollution) still happens...

即使有cgroups资源隔离，但是还是可能互相影响。

> A second split is between compressible resources (e.g.,CPU cycles, disk I/O bandwidth) that are rate-based and can be reclaimed from a task by decreasing its quality of service without killing it; and non-compressible resources (e.g., memory, disk space) which generally cannot be re- claimed without killing the task. If a machine runs out of non-compressible resources, the Borglet immediately termi- nates tasks, from lowest to highest priority, until the remain- ing reservations can be met. If the machine runs out of com- pressible resources, the Borglet throttles usage (favoring LS tasks) so that short load spikes can be handled without killing any tasks. If things do not improve, Borgmaster will remove one or more tasks from the machine...

这部分实际上是单机资源的精细化控制，如何尽量保证task的存活率的同时，减小资源隔离性能的相互影响，如何根据当前机器上service，batch job，best effort的任务消耗的资源量，来对将来可能需要消耗的资源量做预估和微调。比如，如果service对可压缩资源比如cpu的需求量增加，那么可以throttle其他低优先级的任务一段时间比如几分钟，而不直接杀死低优先级任务，因为可能只是短暂的流量尖峰。另一个是，对于可压缩资源，task可以适当消耗超过limit的部分。这一块也是挺精细复杂的。



----



#### 资源利用率小结
+ 提高资源利用率的一些核心思路：
    + 在离线混部，混部完肯定能大幅提高资源利用率
    + 装箱调度算法的优化
    + 资源reclaim和资源over-commit，即混部完后还能怎么扣空闲资源出来用，资源超发应该站在整个集群的层面来看，承诺出去的资源量超过了集群实际的资源量，当然使用量不会超过集群实际的资源量，在离线混部通常不会导致超发，而resource reclaimation可能导致超发。超发不是单机上的概念。
    + 单机资源的精细化控制，比如对于可压缩资源，保证高优先级的在线服务需求外，节流低优先级的任务，而不立马杀掉，保证低优先级任务的较高的存活性。
