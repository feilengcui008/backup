title: Linux下的时间
date: 2016-05-16 17:03:34
tags: [Linux]
categories: [系统]
---

### 时钟

+ 硬件时钟
    + RTC(real time clock)，记录wall clock time，硬件对应到/dev/rtc设备文件，读取设备文件可得到硬件时间
    + 读取方式
        + 通过ioctl
          ````
          #include <linux/rtc.h>
          int ioctl(fd, RTC_request, param);
          ````
        + hwclock命令
    + 通常内核在boot以及从低电量中恢复时，会读取RTC更新system time


+ 软件时钟
    + HZ and jiffies, 由内核维护，对于PC通常HZ配置为 1s / 10ms = 100
    + 精度影响select等依赖timeout的系统调用 
    + HRT(high-resolution timers). Linux 2.6.21开始，内核支持高精度定时器，不受内核jiffy限制，可以达到硬件时钟的精度。

+ 外部时钟
    + 从网络ntp，原子钟等同步


----

### 时间

+ 时间类别
    + wall clock time => 硬件时间
    + real time => 从某个时间点(比如Epoch)开始的系统时间
    + sys and user time => 通常指程序在内核态和用户态花的时间 

+ 时间的表示
    + time_t 从Epoch开始的秒数
    + calendar time 字符串
    + 拆分时间 struct tm
      ```
      struct tm {
        int tm_sec;         /* seconds */
        int tm_min;         /* minutes */
        int tm_hour;        /* hours */
        int tm_mday;        /* day of the month */
        int tm_mon;         /* month */
        int tm_year;        /* year */
        int tm_wday;        /* day of the week */
        int tm_yday;        /* day in the year */
        int tm_isdst;       /* daylight saving time */
      };
      ```
    + struct timeval/struct timespec
    ```
    struct timeval {
      time_t seconds;
      suseconds_t useconds;
    }

    struct timespec {
      time_t   tv_sec;        /* seconds */
      long     tv_nsec;       /* nanoseconds */
    };
    ```


----


### 系统时间的操作

```
#include <time.h>
#include <sys/time.h>

// number of seconds since epoch
time_t time(time_t *t) 

//参数time_t*
char *ctime(const time_t *timep);
char *ctime_r(const time_t *timep, char *buf);

struct tm *gmtime(const time_t *timep);
struct tm *gmtime_r(const time_t *timep, struct tm *result);

struct tm *localtime(const time_t *timep);
struct tm *localtime_r(const time_t *timep, struct tm *result);

//参数struct tm*
char *asctime(const struct tm *tm);
char *asctime_r(const struct tm *tm, char *buf);
time_t mktime(struct tm *tm);


int gettimeofday(struct timeval *tv, struct timezone *tz);//如果系统时间调整了会影响
int clock_gettime(clockid_t clk_id, struct timespec *tp);

//将tm按照format处理后放到s
size_t strftime(char *s, size_t max, const char *format, const struct tm *tm);

//将字符串时间s按照format格式化后放入tm
char *strptime(const char *s, const char *format, struct tm *tm);

```


----


### 定时器

+ sleep
```
unsigned int sleep(unsigned int seconds);
```
+ usleep 
```
int usleep(useconds_t usec);
```
+ nanosleep
```
int nanosleep(const struct timespec *req, struct timespec *rem);
```
+ alarm 
```
// SIGALARM after seconds
unsigned int alarm(unsigned int seconds);
```
+ timer_create
```
int timer_create(clockid_t clockid, struct sigevent *sevp,
                        timer_t *timerid);
```
+ setitimer 
+ timerfd_create ＋ select/poll/epoll
```
int timerfd_create(int clockid, int flags);
```
+ select 
```
// struct timeval可以精确到微秒(如果硬件有高精度时钟支持)
int select(int nfds, fd_set *readfds, fd_set *writefds,
                  fd_set *exceptfds, struct timeval *timeout);
// struct timespec可以精确到纳秒，但是pselect下次无法修改timeout 
int pselect(int nfds, fd_set *readfds, fd_set *writefds,
                   fd_set *exceptfds, const struct timespec *timeout,
                   const sigset_t *sigmask);

// 一般能提供周期，延时，时间点触发，但核心还是时间点触发的timer
// 1.call_period => 触发一次重新注册call_at
// 2.call_later => 转换为call_at 
// 3.call_at => 时间点触发的timer可以用一个优先级队列保存

```
+ poll 
```
// timeout最小单位ms，并且rounded up to系统时钟的精度
int poll(struct pollfd *fds, nfds_t nfds, int timeout);
// 注意timespec会被转换成ms
int ppoll(struct pollfd *fds, nfds_t nfds,
               const struct timespec *timeout_ts, const sigset_t *sigmask);

```
+ epoll 
```
// timeout最小单位ms，并且rounded up to系统时钟的精度
int epoll_wait(int epfd, struct epoll_event *events,
                      int maxevents, int timeout);
int epoll_pwait(int epfd, struct epoll_event *events,
                      int maxevents, int timeout,
                      const sigset_t *sigmask);
```

+ eventfd + select/poll/epoll
一个fd可同时负责读接受事件通知和写触发事件通知

+ signaled + select/poll/epoll 
借助alarm/setitimer/timer_create等触发的SIGALARM，通过signalfd传递到多路复用中

+ pipe + select/poll/epoll 
一端另起线程定时触发，另一端放到多路复用中
