title: Go的context包实现分析
date: 2017-04-24 21:07:23
tags: [Go]
categories: [编程语言]
---

Go1.7引入了context包，并在之后版本的标准库中广泛使用，尤其是net/http包。context包实现了一种优雅的并发安全的链式或树状通知机制，并且带取消、超时、值传递的特性，其底层还是基于channel、goroutine和time.Timer。通常一段应用程序会涉及多个树状的处理逻辑，树的节点之间存在一定依赖关系，比如子节点依赖父节点的完成，如果父节点退出，则子节点需要立即退出，所以这种模型可以比较优雅地处理程序的多个逻辑部分，而context很好地实现了这个模型。对于请求响应的形式(比如http)尤其适合这种模型。下面分析下context包的具体实现。



----


## 基本设计
+ context的类型主要有emptyCtx(用于默认Context)、cancelCtx(带cancel的Context)、timerCtx(计时并带cancel的Context)、valueCtx(携带kv键值对)，多种类型可以以父子节点形式相互组合其功能形成新的Context。
+ cancelCtx是最核心的，是WithCancel的底层实现，且可包含多个cancelCtx子节点，从而构成一棵树。
+ emptyCtx目前有两个实例化的ctx: background和TODO，background作为整个运行时的默认ctx，而TODO主要用来临时填充未确定具体Context类型的ctx参数
+ timerCtx借助cancelCtx实现，只是其cancel的调用可由time.Timer的事件回调触发，WithDeadline和WithTimeout的底层实现。
+ cancelCtx的cancel有几种方式
    + 主动调用cancel
    + 其父ctx被cancel，触发子ctx的cancel
    + time.Timer事件触发timerCtx的cancel回调
+ 当一个ctx被cancel后，ctx内部的负责通知的channel被关闭，从而触发select此channel的goroutine获得通知，完成相应逻辑的处理

----


## 具体实现

+ Context接口
```
type Context interface {
  // 只用于timerCtx，即WithDeadline和WithTimeout
  Deadline() (deadline time.Time, ok bool)
  // 需要获取通知的goroutine可以select此chan，当此ctx被cancel时，会close此chan
  Done() <-chan struct{}
  // 错误信息
  Err() error
  // 只用于valueCtx
  Value(key interface{}) interface{}
}

```

+ 几种主要Context的实现
```
// cancelCtx
type cancelCtx struct {
  Context
  mu       sync.Mutex            
  done     chan struct{}         
  // 主要用于存储子cancelCtx和timerCtx
  // 当此ctx被cancel时，会自动cancel其所有children中的ctx
  children map[canceler]struct{} 
  err      error                 
}
// timeCtx
type timerCtx struct {
  cancelCtx
  // 借助计时器触发timeout事件
  timer *time.Timer
  deadline time.Time
}
// valueCtx 
type valueCtx struct {
  Context
  key, val interface{}
}

// cancel逻辑
func (c *cancelCtx) cancel(removeFromParent bool, err error) {
  /* ... */
  c.err = err
  // 如果在第一次调用Done之前就调用cancel，则done为nil
  if c.done == nil {
    c.done = closedchan
  } else {
    close(c.done)
  }
  for child := range c.children {
    // NOTE: acquiring the child's lock while holding parent's lock.
    // 不能将子ctx从当前移除，由于移除需要拿当前ctx的锁
    child.cancel(false, err)
  }
  // 直接置为nil让gc处理子ctx的回收?
  c.children = nil
  c.mu.Unlock()

  // 把自己从parent里移除，注意这里需要拿parent的锁
  if removeFromParent {
    removeChild(c.Context, c)
  }
}
```

+ 外部接口
```
// Background
func Background() Context {
  // 直接返回默认的顶层ctx
  return background
}

// WithCancel
func WithCancel(parent Context) (ctx Context, cancel CancelFunc) {
  // 实例化cancelCtx
  c := newCancelCtx(parent)
  // 如果parent是cancelCtx类型，则注册到parent.children，否则启用
  // 新的goroutine专门负责此ctx的cancel，当parent被cancel后，自动
  // 回调child的cancel
  propagateCancel(parent, &c)
  return &c, func() { c.cancel(true, Canceled) }
}

// WithDeadline
func WithDeadline(parent Context, deadline time.Time) (Context, CancelFunc) {
  // 如果parent是deadline，且比当前早，则直接返回cancelCtx
  if cur, ok := parent.Deadline(); ok && cur.Before(deadline) {
    return WithCancel(parent)
  }
  c := &timerCtx{
    cancelCtx: newCancelCtx(parent),
    deadline:  deadline,
  }
  propagateCancel(parent, c)
  d := time.Until(deadline)
  // 已经过了
  if d <= 0 {
    c.cancel(true, DeadlineExceeded) // deadline has already passed
    return c, func() { c.cancel(true, Canceled) }
  }
  c.mu.Lock()
  defer c.mu.Unlock()
  if c.err == nil {
    // time.Timer到时则自动回调cancel
    c.timer = time.AfterFunc(d, func() {
      c.cancel(true, DeadlineExceeded)
    })
  }
  return c, func() { c.cancel(true, Canceled) }
}

// WithTimeout
func WithTimeout(parent Context, timeout time.Duration) (Context, CancelFunc) {
  // 直接使用WithDeadline的实现即可
  return WithDeadline(parent, time.Now().Add(timeout))
}

```

----


## 简单例子

```
package main

import (
  "context"
  "fmt"
  "time"
)

func OuterLogicWithContext(ctx context.Context, fn func(ctx context.Context) error) error {
  go fn(ctx)
  for {
    select {
    case <-ctx.Done():
      fmt.Println("OuterLogicWithContext ended")
      return ctx.Err()
    }
  }
}

func InnerLogicWithContext(ctx context.Context) error {
Loop:
  for {
    select {
    case <-ctx.Done():
      break Loop
    }
  }
  fmt.Println("InnerLogicWithContext ended")
  return ctx.Err()
}

func main() {
  ctx := context.Background()
  var cancel context.CancelFunc
  ctx, cancel = context.WithCancel(ctx)
  ctx, cancel = context.WithTimeout(ctx, time.Second)
  go OuterLogicWithContext(ctx, InnerLogicWithContext)
  time.Sleep(time.Second * 3)
  // has been canceled by timer
  cancel()
  fmt.Println("main ended")
}
```
