title: Go的自举
date: 2017-04-27 15:37:35
tags: [Go]
categories: [编程语言]
---

Go从1.5开始就基本全部由.go和.s文件写成了，.c文件被全部重写。了解Go语言的自举是很有意思的事情，能帮助理解Go的编译链接流程、Go的标准库和二进制工具等。本文基于go1.8的源码分析了编译时的自举流程。


## 基本流程

Go的编译自举流程分为以下几步(假设这里老版本的Go为go_old):
+ 1. go_old -> dist: 用老版本的Go编译出新代码的dist工具
+ 2. go_old + dist -> asm, compile, link: 用老版本的Go和dist工具编译出bootstrap工具，asm用于汇编源码中的.s文件，输出.o对象文件；compile用于编译源码中的.go文件，输出归档打包后的.a文件；link用于链接二进制文件。这里还要依赖外部的pack程序，负责归档打包编译的库。

到这里，dist/asm/compile/link都是链接的老的runtime，所以其运行依赖于go_old。

+ 3. asm, compile, link -> go_bootstrap: 这里用新代码的asm/compile/link的逻辑编译出新的go二进制文件及其依赖的所有包，包括新的runtime。

+ 4. go_bootstrap install std cmd: 重新编译所有的标准库和二进制文件，替换之前编译的所有标准库和二进制工具(包括之前编译的dist,asm,link,compile等)，这样标准库和二进制工具依赖的都是新的代码编译生成的runtime，而且是用新的代码本身的编译链接逻辑。(这里go_bootstrap install会使用上一步的asm,compile,link工具实现编译链接，虽然其用的是go_old的runtime，但是这几个工具已经是新代码的编译链接逻辑)。


一句话总结，借用老的runtime编译新的代码逻辑(编译器、链接器、新的runtime)生成新代码的编译、链接工具，并用这些工具重新编译新代码和工具本身。

----


## 具体实现

+ 生成dist
```
// make.bash
# 编译cmd/dist，需要在host os和host arch下编译(dist需要在本地机器运行)，因此这里把环境变量清掉了
# 注意在bash中，单行的环境变量只影响后面的命令，不会覆盖外部环境变量!!!
GOROOT="$GOROOT_BOOTSTRAP" GOOS="" GOARCH="" "$GOROOT_BOOTSTRAP/bin/go" build -o cmd/dist/dist ./cmd/dist
```

+ 生成bootstrap二进制文件和库
```
// make.bash
# 设置环境变量
eval $(./cmd/dist/dist env -p || echo FAIL=true)

# 编译cmd/compile, cmd/asm, cmd/link, cmd/go bootstrap工具，注意外部传进来的GOOS和GOARCH目标平台的环境变量
# 这里可提供GOARCH和GOOS环境变量交叉编译
./cmd/dist/dist bootstrap $buildall $GO_DISTFLAGS -v # builds go_bootstrap
```

+ 重新生成当前平台的go
```
// make.bash
// std, cmd, all在go里有特殊的含义，这里重新编译了所有标准库和默认工具的二进制程序
if [ "$GOHOSTARCH" != "$GOARCH" -o "$GOHOSTOS" != "$GOOS" ]; then
  echo "##### Building packages and commands for host, $GOHOSTOS/$GOHOSTARCH."
  # 重置GOOS和GOARCH环境变量，不会影响外层的环境变量
  CC=$CC GOOS=$GOHOSTOS GOARCH=$GOHOSTARCH \
    "$GOTOOLDIR"/go_bootstrap install -gcflags "$GO_GCFLAGS" -ldflags "$GO_LDFLAGS" -v std cmd
  echo
fi
```

+ 生成目标平台的Go
```
CC=$CC_FOR_TARGET "$GOTOOLDIR"/go_bootstrap install $GO_FLAGS -gcflags "$GO_GCFLAGS" -ldflags "$GO_LDFLAGS" -v std cmd
```


+ dist bootstrap逻辑
```
// cmd/dist
dist的bootstrap逻辑不具体分析了，基本过程是先编译好asm, compile, link工具，然后用它们编译cmd/go及其依赖的runtime和标准库。中间主要是用compile编译.go文件、asm汇编.s文件和用link/pack链接归档打包目标文件的过程。
```

----

## 小问题
分析代码中遇到几个值得注意的小问题:
+ bash环境变量
    + bash脚本单行命令中修改环境变量只影响其后执行的程序，而不会覆盖当前环境变量。
+ go tool的二进制程序安装路径
    + `go install`命令会自动将tool类型的二进制文件安装到`$GOROOT/pkg/tool/`目录下。

