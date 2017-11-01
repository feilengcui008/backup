title: Go接口详解
date: 2017-04-30 14:45:23
tags: [Go]
categories: [编程语言]
---

Go接口的设计和实现是Go整个类型系统的一大特点。接口嵌入和组合、duck typing等实现了优雅的代码复用、解耦、模块化的特性，而且接口是方法动态分派、反射的实现基础(当然更基础的是编译为运行时提供的类型信息)。理解了接口的实现之后，就不难理解"著名"的nil返回值问题以及反射、type switch、type assertion等原理。本文主要基于Go1.8.1的源码介绍接口的内部实现及其使用相关的问题。


----


## 1. 接口的实现
+ 下面是接口在runtime中的实现，注意其中包含了接口本身和实际数据类型的类型信息:
```
// src/runtime/runtime2.go
type iface struct {
  // 包含接口的静态类型信息、数据的动态类型信息、函数表
  tab  *itab
  // 指向具体数据的内存地址比如slice、map等，或者在接口
  // 转换时直接存放小数据(一个指针的长度)
  data unsafe.Pointer
}
type itab struct {
  // 接口的类型信息
  inter  *interfacetype
  // 具体数据的类型信息
  _type  *_type
  link   *itab
  hash   uint32
  bad    bool
  inhash bool
  unused [2]byte
  // 函数地址表，这里放置和接口方法对应的具体数据类型的方法地址
  // 实现接口调用方法的动态分派，一般在给接口赋值发生转换时候会
  // 更新此表，或者从直接拿缓存的itab
  fun    [1]uintptr // variable sized
}
```

+ 另外，需要注意与接口相关的两点优化，会影响到反射等的实现:
  + (1) 空接口(interface{})的itab优化。当将某个类型的值赋给空接口时，由于空接口没有方法，所以空接口的tab会直接指向数据的具体类型。在Go的reflect包中，`reflect.TypeOf`和`reflect.ValueOf`的参数都是空接口，因此所有参数都会先转换为空接口类型。这样，反射就实现了对所有参数类型获取实际数据类型的统一。这在后面反射的基本实现中会分析到。
  + (2) 发生接口转换时data字段相关的优化。当被转换为接口的数据的类型长度不超过一个指针的长度时(比如pointer、map、func、chan、[1]int等类型)，接口转换时会将数据直接拷贝存放到接口的data字段中(DirectIface)，而不再额外分配内存并拷贝。另外，从go1.8+的源码来看除了DirectIface的优化以外，还对长度较小(不超过64字节，未初始化数据内存的array，空字符串等)的零值做了优化，也不会重新分配内存，而是直接指向一个包级全局数组变量zeroVal的首地址。注意第2点优化发生在接口转换时生成的临时接口上，而不是被赋值的接口左值上。

+ 再者，在Go中只有值传递，与具体的类型实现无关，但是某些类型具有引用的属性。典型的9种非基础类型中:
  + array传递会拷贝整块数据内存，传递长度为len(arr) * Sizeof(elem)
  + string、slice、interface传递的是其runtime的实现，所以长度是固定的，分别为16、24、16字节(amd64)
  + map、func、chan、pointer传递的是指针，所以长度固定为8字节(amd64)
  + struct传递的是所有字段的内存拷贝，所以长度是所有字段的长度和
  + 详细的测试可以参考[这段程序](https://github.com/feilengcui008/go-pieces/blob/master/src/pass_by_value_main.go)


----


## 2. runtime中接口的转换操作
接口相关的操作主要在于对其内部字段itab的操作，因为接口转换最重要的是类型信息。这里简单分析几个runtime中相关的函数。主要实现在`src/runtime/iface.go`中。值得注意的是，接口的类型转换在编译期会生成一个函数调用的语法树节点(OCALL)，调用runtime提供的相应接口转换函数完成接口的类型设置，所以接口的转换是在运行时发生的，其具体类型的方法地址表也是在运行时填写的，这一点和C++的虚函数表不太一样。另外，由于在运行时转换会产生开销，所以对转换的itab做了缓存。
```
type MyReader struct {
}
func (r MyReader) Read(b []byte) (n int, err error) {
}
// 接口的相关转换编译成对相关runtime函数的调用，比如convI2I/assertI2I等
var i io.Reader = MyReader{}
realReader := i.(MyReader)
var ei interface{} = interface{}(realReader)
```

下面以convI2I为例来说明，编译时生成OCALL语法树节点的过程。
```
// src/cmd/compile/internal/gc/walk.go
func convFuncName(from, to *types.Type) string {
	tkind := to.Tie()
	switch from.Tie() {
        // 将接口转换为另一接口，返回需要在runtime中调用的函数名
	case 'I':
		switch tkind {
		case 'I':
			return "convI2I"
		}
	case 'T':
		/* ... */
}
// src/cmd/compile/internal/gc/walk.go
// 这里只给出节点操作类型为OCONVIFACE(即inerface转换)的处理逻辑
func walkexpr(n *Node, init *Nodes) *Node {
    case OCONVIFACE:
        n.Left = walkexpr(n.Left, init)
        /* 这里省略了很多特殊的处理逻辑，比如空接口相关的优化 */

        // 到这里开始进入一般的接口转换
   	// 查找需要调用的runtime的函数，在Runtimepkg中查找
        fn := syslook(convFuncName(n.Left.Type, n.Type))
	fn = substArgTypes(fn, n.Left.Type, n.Type)
	dowidth(fn.Type)
 	// 生成函数调用节点
	n = nod(OCALL, fn, nil)
	n.List.Set(ll)
	n = typecheck(n, Erv)
	n = walkexpr(n, init)	
}
```

一旦itab的函数表设置后，后面的接口的方法调用只需要一次间接调用的开销，不需要反复查找方法的地址。关于接口的实现，Russ Cox写过一篇很好的[文章](http://research.swtch.com/2009/12/go-data-structures-interfaces.html)


下面分析runtime中接口相关的几个主要函数:
+ getitab
```
// 根据接口类型和实际数据类型生成itab
func getitab(inter *interfacetype, typ *_type, canfail bool) *itab {
  // 先从缓存中找
  h := itabhash(inter, typ)
  // look twice - once without lock, once with.
  // common case will be no lock contention.
  var m *itab
  var locked int
  for locked = 0; locked < 2; locked++ {
    if locked != 0 {
      lock(&ifaceLock)
    }
    for m = (*itab)(atomic.Loadp(unsafe.Pointer(&hash[h]))); m != nil; m = m.link {
      // 找到
      if m.inter == inter && m._type == typ {
        if m.bad {
          if !canfail {
            // 检查并绑定方法地址表
            additab(m, locked != 0, false)
          }
          m = nil
        }
        if locked != 0 {
          unlock(&ifaceLock)
        }
        return m
      }
    }
  }

  // 缓存中没找到则分配itab的内存: itab结构本身内存 + 末尾存方法地址表的可变长度
  m = (*itab)(persistentalloc(unsafe.Sizeof(itab{})+uintptr(len(inter.mhdr)-1)*sys.PtrSize, 0, &memstats.other_sys))
  m.inter = inter           // 设置接口类型信息
  m._type = typ             // 设置实际数据类型信息
  additab(m, true, canfail) // 设置itab函数调用表
  unlock(&ifaceLock)
  if m.bad {
    return nil
  }
  return m
}
```

+ additab
```
// 检查具体类型是否实现了接口规定的方法，并使用具体类型的方法
// 地址填充方法表。
func additab(m *itab, locked, canfail bool) {
  inter := m.inter
  typ := m._type
  x := typ.uncommon()
  ni := len(inter.mhdr) // 接口方法数量
  nt := int(x.mcount)   // 实际数据类型方法数量
  xmhdr := (*[1 << 16]method)(add(unsafe.Pointer(x), uintptr(x.moff)))[:nt:nt]
  j := 0
  for k := 0; k < ni; k++ {
    // 对每个接口方法的地址
    i := &inter.mhdr[k]
    // 使用接口的类型信息获取实际类型, 函数名字，包名字
    itype := inter.typ.typeOff(i.ityp)
    name := inter.typ.nameOff(i.name)
    iname := name.name()
    ipkg := name.pkgPath()
    if ipkg == "" {
      ipkg = inter.pkgpath.name()
    }
    for ; j < nt; j++ {
      // 对每个具体类型的方法
      t := &xmhdr[j]
      tname := typ.nameOff(t.name)
      // 具体类型的方法类型和接口方法的类型相同，并且名字相同，则匹配成功
      if typ.typeOff(t.mtyp) == itype && tname.name() == iname {
        pkgPath := tname.pkgPath()
        if pkgPath == "" {
          pkgPath = typ.nameOff(x.pkgpath).name()
        }
        if tname.isExported() || pkgPath == ipkg {
          if m != nil {
            // 具体类型的某个方法地址
            ifn := typ.textOff(t.ifn)
            // 填充itab的func表地址
            *(*unsafe.Pointer)(add(unsafe.Pointer(&m.fun[0]), uintptr(k)*sys.PtrSize)) = ifn
          }
          goto nextimethod
        }
      }
    }
    // didn't find method
    // 不匹配panic
    if !canfail {
      if locked {
        unlock(&ifaceLock)
      }
      panic(&TypeAssertionError{"", typ.string(), inter.typ.string(), iname})
    }
    // 或者设置失败标识
    m.bad = true
    break
  nextimethod:
  }
  if !locked {
    throw("invalid itab locking")
  }
  h := itabhash(inter, typ)
  m.link = hash[h]
  m.inhash = true
  // 存到itab的hash表缓存
  atomicstorep(unsafe.Pointer(&hash[h]), unsafe.Pointer(m))
}
```

+ convI2I
```
// 将已有的接口，转换为新的接口类型，失败panic
// 比如:
// var rc io.ReadCloser
// var r io.Reader
// rc = io.ReadCloser(r)
func convI2I(inter *interfacetype, i iface) (r iface) {
  tab := i.tab
  if tab == nil {
    return
  }
  // 接口类型相同直接赋值即可
  if tab.inter == inter {
    r.tab = tab
    r.data = i.data
    return
  }
  // 否则重新生成itab
  r.tab = getitab(inter, tab._type, false)
  // 注意这里没有分配内存拷贝数据
  r.data = i.data
  return
}
```


+ convT2I
```
// 使用itab并拷贝数据，得到iface
func convT2I(tab *itab, elem unsafe.Pointer) (i iface) {
  t := tab._type
  if raceenabled {
    raceReadObjectPC(t, elem, getcallerpc(unsafe.Pointer(&tab)), funcPC(convT2I))
  }
  if msanenabled {
    msanread(elem, t.size)
  }
  // 注意这里发生了内存分配和数据拷贝
  x := mallocgc(t.size, t, true)
  // memmove内部的拷贝对大块内存做了优化
  typedmemmove(t, x, elem)
  i.tab = tab
  i.data = x
  return
}
```

从上面convX2I我们可以看到，在接口类型之间转换时，并没有分配内存和拷贝数据，但是将非接口类型转换为接口类型时，却发生了内存分配和数据拷贝。这里的原因是Go接口的数据不能被改变，所以接口之间的转换可以使用同一块内存，但是其他情况为了避免外部改变导致接口内数据改变，所以会进行内存分配和数据拷贝。另外，这也是反射非指针变量时无法直接改变变量数据的原因，因为反射会先将变量转换为空接口类型可以参考[go-nuts](https://groups.google.com/forum/#!topic/golang-nuts/e5ddPzR7eKI)。这里我们用一个简单的程序测试一下。
```
package main

import "fmt"

type Data struct {
  n int
}

func main() {
  d := Data{10}
  fmt.Printf("address of d: %p\n", &d)
  // assign not interface type variable to interface variable
  // d will be copied
  var i1 interface{} = d
  // assign interface type variable to interface variable
  // the data of i1 will directly assigned to i2.data and will not be copied
  var i2 interface{} = i1

  fmt.Println(d)
  fmt.Println(i1)
  fmt.Println(i2)
}

// 关掉优化和inline
go build -gcflags "-N -l" interface.go

// 可以看到接口变量i1和i2的数据地址是相同的，但是d和i1的数据地址不相同
(gdb) info locals 
&d = 0xc420074168
i2 = {_type = 0x492e00, data = 0xc4200741a0}
i1 = {_type = 0x492e00, data = 0xc4200741a0}

```


----


## 3. type assertion与type switch
理解了接口的实现，不难猜测type assertion和type switch的实现逻辑，我们只需要取出接口的动态类型(数据类型)与目标类型做比较即可，而目标类型的信息在编译器是可以确定下来的。可参考[Effective Go](https://golang.org/doc/effective_go.html#interface_conversions)中的简单例子。



----


## 4. nil接口的问题
具体的代码可参考[nil接口返回值测试](https://github.com/feilengcui008/go-pieces/blob/master/src/traps_main.go#L94)。理解了接口的底层实现，这个问题其实也比较好理解了。需要说明的是nil在Go中既指空值，也指空类型。这里的空值并非零值，空值是指未初始化，比如slice没有分配底层的内存。只有chan、interface、func、slice、map、pointer可直接与nil比较和用nil赋值。对于非接口类型来说，对其赋值nil的语义是将其数据变为未初始化的状态，而给接口类型来说，还会将接口的类型信息字段itab置nil。所以:
```
type MyReader interface {
}
var r MyReader  // (nil, nil)
var n *int = nil
var r1 MyReader = n // (*int, nil)
var r2 MyReader // (nil, nil)
var inter interface{} = r2 // (nil, nil)
```


----


## 5. 接口与反射
反射实现的一个基本前提是编译期为运行时提供足够的类型信息，一般来说都会使用一个基本类型(比如Go中的interface、Java中的Object)来存放具体类型的信息，以便在运行时使用。C++到目前为止也没有比较成熟的反射库，大部分原因就是没有比较好的方法提供运行时所需的类型信息，typeid等运行时信息太原始了。Go的反射的实现就是基于interface的。这里简单分析两个常用方法`reflect.TypeOf, reflect.ValueOf`的实现。
```
// src/reflect/value.go
// 注意: 从前面的分析可知当转换为空接口的时候，itab指针会
// 直接指向数据的实际类型，所以反射的入口函数参数类型是interface{}，
// 转换后，emptyInterface的rtype字段会直接指向数据类型，所以
// 整个反射才能直接得到数据类型，不然itab指向内存的前面部分包
// 含的是接口的静态类型信息
type emptyInterface struct {
  typ  *rtype
  word unsafe.Pointer
}

// src/reflect/type.go
func TypeOf(i interface{}) Type {
  // 参数i已经是空接口类型
  eface := *(*emptyInterface)(unsafe.Pointer(&i))
  return toType(eface.typ)
}

// src/reflect/value.go
func ValueOf(i interface{}) Value {
  if i == nil {
    return Value{}
  }
  escapes(i)
  return unpackEface(i)
}
// src/reflect/value.go
func unpackEface(i interface{}) Value {
  // 参数i已经是空接口类型
  e := (*emptyInterface)(unsafe.Pointer(&i))
  t := e.typ
  if t == nil {
    return Value{}
  }
  f := flag(t.Kind())
  if ifaceIndir(t) {
    f |= flagIndir
  }
  return Value{t, e.word, f}
}
```


----


## 6. 接口与duck typing
严格说来，Go的接口可能并不算真正的duck typing，看一个Python和Go对比的例子。在这个例子中我们并不管传入的类型是什么，也不用在乎Say方法返回的类型是什么。而在Go中，实现接口的Say方法的返回值类型也必须相同。但是，这两个例子中都不需要显示指定实现的接口，这对于代码的重构极其有利，这也是Go的接口相对于Java等接口的优势。
```
# python duck typing
def callSay(a):
    ret = a.Say()
    print ret

class SayerInt(object):
    def Say():
        return 1

class SayerString(object):
    def Say():
        return "string"
si = SayerInt()
ss = SayerString()
callSay(si)
callSay(ss)

// Go
type Sayer interface {
  Say() int
}
func callSay(sayer Sayer) {
  sayer.Say()
}

type Say1Struct struct {
}

func (s Say1Struct) Say() int {
  return 1
}

type Say2Struct struct {
}

func (s Say2Struct) Say() int {
  return 2
}

s1 := &Say1Struct{}
s2 := &Say2Struct{}
callSay(s1)
callSay(s2)
```

----


## 7. 总结

综上，接口在Go的整个类型系统起到重要的作用，且是反射、方法动态分派、type switch、type assertion等的实现基础。另外，接口组合和duck typing特性也让整个类型层次变得更加扁平，写起来更加简洁且有利于重构。理解了接口的底层实现，也更容易避免Go使用中的很多问题。

