title: Redis源码分析
date: 2016-05-29 21:05:05
tags: [Redis]
categories: [系统]
---

主要记录Redis相关的一些源码分析，不定时更新。

目前已添加的内容：

+ Redis之eventloop
+ Redis数据结构之dict

----

## Redis之eventloop

#### 简介
Redis的eventloop实现也是比较平常的，主要关注文件描述符和timer相关事件，而且timer只是简单用一个单链表(O(n)遍历寻找最近触发的时间)实现。


#### 流程

+ 主要在initServer(server.c)中初始化整个eventloop相关的数据结构与回调

```
// 注册系统timer事件
if (aeCreateTimeEvent(server.el, 1, serverCron, NULL, NULL) == AE_ERR) {
  serverPanic("Can't create event loop timers.");
  exit(1);
}

// 注册poll fd的接收客户端连接的读事件
for (j = 0; j < server.ipfd_count; j++) {
  if (aeCreateFileEvent(server.el, server.ipfd[j], AE_READABLE,
        acceptTcpHandler,NULL) == AE_ERR)
  {
    serverPanic(
        "Unrecoverable error creating server.ipfd file event.");
  }
}
// 同上
if (server.sofd > 0 && aeCreateFileEvent(server.el,server.sofd,AE_READABLE,
      acceptUnixHandler,NULL) == AE_ERR) serverPanic("Unrecoverable error creating server.sofd file event.");

```

+ acceptTcpHandler处理客户端请求，分配client结构，注册事件

```
cfd = anetTcpAccept(server.neterr, fd, cip, sizeof(cip), &cport);
acceptCommonHandler(cfd,0,cip);


```

+ createClient，创建客户端

```
// receieved a client, alloc client structure 
// and register it into eventpoll
client *createClient(int fd) {
client *c = zmalloc(sizeof(client));
if (fd != -1) {
  anetNonBlock(NULL,fd);
  anetEnableTcpNoDelay(NULL,fd);
  if (server.tcpkeepalive)
    anetKeepAlive(NULL,fd,server.tcpkeepalive);
  // register read event for client connection
  // the callback handler is readQueryFromClient
  // read into client data buffer
  if (aeCreateFileEvent(server.el,fd,AE_READABLE,
        readQueryFromClient, c) == AE_ERR)
  {
    close(fd);
    zfree(c);
    return NULL;
  }
}

```

+ client读事件触发，读到buffer，解析client命令

```
dQueryFromClient(aeEventLoop *el, int fd, void *privdata, int mask) 
--> processInputBuffer 

// handle query buffer
// in processInputBuffer(c);
if (c->reqtype == PROTO_REQ_INLINE) {
    if (processInlineBuffer(c) != C_OK) break;
} else if (c->reqtype == PROTO_REQ_MULTIBULK) {
    if (processMultibulkBuffer(c) != C_OK) break;
} else {
    serverPanic("Unknown request type");
}

/* Multibulk processing could see a <= 0 length. */
if (c->argc == 0) {
    resetClient(c);
} else {
    /* Only reset the client when the command was executed. */
    // handle the client command 
    if (processCommand(c) == C_OK)
        resetClient(c);
    /* freeMemoryIfNeeded may flush slave output buffers. This may result
     * into a slave, that may be the active client, to be freed. */
    if (server.current_client == NULL) break;
}

```

+ 处理客户端命令

```
// in processCommand 
/* Exec the command */
if (c->flags & CLIENT_MULTI &&
    c->cmd->proc != execCommand && c->cmd->proc != discardCommand &&
    c->cmd->proc != multiCommand && c->cmd->proc != watchCommand)
{
    queueMultiCommand(c);
    addReply(c,shared.queued);
} else {
    // call the cmd 
    // 进入具体数据结构的命令处理
    call(c,CMD_CALL_FULL);
    c->woff = server.master_repl_offset;
    if (listLength(server.ready_keys))
        handleClientsBlockedOnLists();
}

```


#### 其他注意点

+ 关于timer的实现没有采用优先级队列(O(logn))等其他数据结构，而是直接采用O(n)遍历的单链表，是因为一般来说timer会较少?


---- 

## Redis数据结构之dict

#### 主要特点

Redis的hashtable实现叫dict，其实现和平常没有太大的区别，唯一比较特殊的地方是每个dict结构内部有两个实际的hashtable结构dictht，是为了实现增量哈希，故名思义，即当第一个dictht到一定负载因子后会触发rehash，分配新的dictht结构的动作和真正的rehash的动作是分离的，并且rehash被均摊到各个具体的操作中去了，这样就不会长时间阻塞线程，因为Redis是单线程。另外，增量hash可以按多步或者持续一定时间做。


#### 主要数据结构

+ dictEntry  =>  hashtable的bucket
+ dictType   =>  规定操作hashtable的接口
+ dictht     =>  hashtable
+ dict       =>  对外呈现的"hashtable"
+ dictIterator  => 迭代器，方便遍历 

```
// dict.h
// hash table entry 
typedef struct dictEntry {
    void *key;  // key 
    union {
        void *val;
        uint64_t u64;
        int64_t s64;
        double d;
    } v;  // value
    struct dictEntry *next;  // linked list 
} dictEntry;

// operations(APIS) of some type of hashtable
typedef struct dictType {
    // hash function 
    unsigned int (*hashFunction)(const void *key);
    // copy key 
    void *(*keyDup)(void *privdata, const void *key);
    // copy value 
    void *(*valDup)(void *privdata, const void *obj);
    // key comparison 
    int (*keyCompare)(void *privdata, const void *key1, const void *key2);
    // dtor for key 
    void (*keyDestructor)(void *privdata, void *key);
    // dtor for value 
    void (*valDestructor)(void *privdata, void *obj);
} dictType;

/* This is our hash table structure. Every dictionary has two of this as we
 * implement incremental rehashing, for the old to the new table. */
// a hashtable 
typedef struct dictht {
    dictEntry **table;  // entries 
    unsigned long size;  // max size 
    unsigned long sizemask;  // mask 
    unsigned long used;  // current used 
} dictht;

typedef struct dict {
    dictType *type;  // type operations 
    void *privdata;  // for extension 
    dictht ht[2];    // two hashtables 
    // rehashing flag
    long rehashidx; /* rehashing not in progress if rehashidx == -1 */
    // users number 
    unsigned long iterators; /* number of iterators currently running */
} dict;

/* If safe is set to 1 this is a safe iterator, that means, you can call
 * dictAdd, dictFind, and other functions against the dictionary even while
 * iterating. Otherwise it is a non safe iterator, and only dictNext()
 * should be called while iterating. */
typedef struct dictIterator {
    dict *d;
    long index;
    int table, safe;
    dictEntry *entry, *nextEntry;
    /* unsafe iterator fingerprint for misuse detection. */
    long long fingerprint;
} dictIterator;

```

#### 主要接口

```
// dict.h
// create
dict *dictCreate(dictType *type, void *privDataPtr);

// expand or initilize the just created dict, alloc second hashtable of dict for incremental rehashing
int dictExpand(dict *d, unsigned long size);

// add, if in rehashing, do 1 step of incremental rehashing
int dictAdd(dict *d, void *key, void *val);
dictEntry *dictAddRaw(dict *d, void *key);

// update, if in rehashing, do 1 step of incremental rehashing
// can we first find and return the entry no matter it is update or add, so 
// we can speed up the update process because no need to do twice find process?
int dictReplace(dict *d, void *key, void *val);
dictEntry *dictReplaceRaw(dict *d, void *key);

// delete if in rehashing, do 1 step of incremental rehashing
int dictDelete(dict *d, const void *key);  // free the memory 
int dictDeleteNoFree(dict *d, const void *key);  // not free the memory

// can we use a double linked list to free the hash table, so speed up?
void dictRelease(dict *d);

// find an entry
dictEntry * dictFind(dict *d, const void *key);
void *dictFetchValue(dict *d, const void *key);

// resize to eh pow of 2 number just >= the used number of slots
int dictResize(dict *d);

// alloc a new iterator
dictIterator *dictGetIterator(dict *d);
// alloc a safe iterator 
dictIterator *dictGetSafeIterator(dict *d);
// next entry 
dictEntry *dictNext(dictIterator *iter);
void dictReleaseIterator(dictIterator *iter);

// random sampling
dictEntry *dictGetRandomKey(dict *d);
unsigned int dictGetSomeKeys(dict *d, dictEntry **des, unsigned int count);

// get stats info
void dictGetStats(char *buf, size_t bufsize, dict *d);

// murmurhash 
unsigned int dictGenHashFunction(const void *key, int len);
unsigned int dictGenCaseHashFunction(const unsigned char *buf, int len);

// empty a dict 
void dictEmpty(dict *d, void(callback)(void*));

void dictEnableResize(void);
void dictDisableResize(void);

// do n steps rehashing
int dictRehash(dict *d, int n);
// do rehashing for a ms milliseconds
int dictRehashMilliseconds(dict *d, int ms);

// hash function seed 
void dictSetHashFunctionSeed(unsigned int initval);
unsigned int dictGetHashFunctionSeed(void);

// scan a dict
unsigned long dictScan(dict *d, unsigned long v, dictScanFunction *fn, void *privdata);

```

#### 一些可能优化的地方

+ 在dictReplace中能否统一add和update的查找，无论是add还是update都返回一个entry，用标识表明是add还是update，而不用在update时做两次查找，从而提升update的性能

+ 在release整个dict时，是循环遍历所有头bucket，最坏情况接近O(n)，能否用双向的空闲链表优化(当然这样会浪费指针所占空间)






