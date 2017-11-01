title: Paper Reading - Lessons learned from three container-management systems over a decade
date: 2017-04-03 14:05:53
tags: [Borg, Omega, Kubernetes, 分布式资源管理与调度]
categories: [系统]
---

### INTRODUCTION

*这一部分精要地描述了Google的三大资源管理与调度系统的发展史，从一定程度上可以看出一个完整的集群管理与调度生态系统的形成过程。*


> Borg shares machines between these two types of applications as a way of increasing resource utilization and thereby reducing costs

最基本的功能，隔离混部提高资源利用率。

> These systems provided mechanisms for configuring and updating jobs; predicting resource requirements; dynamically pushing configuration files to running jobs; service discovery and load balancing; auto-scaling; machine- lifecycle management; quota management; and much more

基本功能完善后，建立和完善周边生态。服务发现，负载均衡，配置管理，自动扩缩容，机器生命周期管理，用户资源配额管理，监控，日志等等，整个生态实际上是非常庞大的。

> Omega stored the state of the cluster in a centralized Paxos-based transaction- oriented store that was accessed by the different parts of the cluster control plane (such as schedulers), using optimistic concurrency control to handle the occasional conflicts.

基本功能和生态逐渐完善后，拆分调度器，便于实验新的调度算法，在调度装箱算法方面做得更细，进一步优化资源利用率。

> Kubernetes was developed with a stronger focus on the experience of developers writing applications that run in a cluster: its main design goal is to make it easy to deploy and manage complex distributed systems, while still benefiting from the improved utilization

内部部分非核心经验提出来开源，提高影响力，建立外部生态。从目前来看，在调度和资源的精细化利用方面，k8s还比较初步，Google应该显然不会很快或者说不会把这些核心的部分开源出来。



----


### CONTAINERS

*容器技术的优势以及其还存在的问题*

> Borg uses containers to co- locate batch jobs with latency-sensitive, user-facing jobs on the same physical machines. The user-facing jobs reserve more resources than they usually need—allowing them to handle load spikes and fail-over—and these mostly-unused resources can be reclaimed to run batch jobs

在离线混部，资源reclaim是提升资源利用率的主要途径，尤其对于中小型公司来说，精细化地研究优化调度算法意义不是太大。

> The isolation is not perfect, though: containers cannot prevent interference in resources that the operating-system kernel doesn’t manage, such as level 3 processor caches and memory bandwidth

单机资源隔离方面，新的隔离资源类型以及隔离的性能(避免过多的相互影响)还有待更加完善。

> it also includes an image—the files that make up the application that runs inside the container

除了基本的隔离机制，还得有一套部署规范，其中包规范起到核心作用。



----



### APPLICATION-ORIENTED INFRASTRUCTURE

*除了数据中心的资源利用率提升以外，基于容器技术的数据中心操作系统在应用开发/运维方面带来的变化*

> Containerization transforms the data center from being machine-oriented to being application-oriented

一个基于容器的数据中心操作系统除了提高资源利用率的基本功能外，还可以作为PaaS/DevOps/CI等面向应用的平台的基础，简化整个研发、上线部署、运维流程。中小型公司应该更看重这一点的价值，因为其规模不大，精细化地去提高资源利用率意义不大，对于大公司来说，两者都有较大的意义。


#### Application environment

> applications share a so-called base image that is installed once on the machine rather than being packaged in each container
> More modern container image formats such as Docker and ACI harden this abstraction further and get closer to the hermetic ideal by eliminating implicit host OS dependencies and requiring an explicit user command to share image data between containers

对于应用部署环境的依赖来说，这两种方式各有好处，前者不用管理本地镜像缓存等问题，但是无法做到应用环境的近完整隔离，后者提供更大的使用友好性，但是会引入一系列镜像文件存储、传输、缓存等问题。较好的方式应该是结合两者的优势，提供基础镜像概念的同时，规范用户对镜像层的使用规范，且做好镜像的管理、传输优化等。


#### Containers as the unit of management

> Building management APIs around containers rather than machines shifts the “primary key” of the data center from machine to application

面向应用管理是提供了很大的透明性，但是往往这个透明性让调试变得很蛋疼，所以做好容器的监控，日志，ui等周边生态很重要。


#### Orchestration is the beginning, not the end

> Many different systems have been built in, on, and around Borg to improve upon the basic container-management services that Borg provided.

周边的生态很重要，服务发现，负载均衡，滚动升级，自动扩缩容，日志管理，监控等等。



----



### THINGS TO AVOID

*一些需要避免的设计缺陷*

> Don’t make the container system manage port numbers

早期应该是没有考虑太多网络隔离相关的事情，端口作为资源来管理相对简单。

> Don’t just number containers: give them labels

打标签，由于每个服务的多样属性，标签极大地方便了服务的管理。

> Be careful with ownership
> Don’t expose raw state

这两点体会还不是太深。。。




----



### SOME OPEN, HARD PROBLEMS

*整个生态中还待解决的问题*

> managing configurations
> Standing up a service typically also means standing up a series of related services

应用的配置管理，多服务的管理，比如服务之间的部署顺序，自动化一棵服务依赖树的部署和管理。




