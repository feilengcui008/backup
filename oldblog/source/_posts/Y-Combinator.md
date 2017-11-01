title: Y Combinator
date: 2015-05-14 19:26:59
categories: [编程语言]
tags: [Lambda, 函数式编程]
---

由于匿名函数(通常成为lambda函数但是跟lambda calculus不同)在递归时无法获得函数名，从而导致一些问题，而Y Combinator能很好地解决这个问题。利用不动点的原理，可以利用一般的函数来辅助得到匿名函数的递归形式，从而间接调用无法表达的真正的匿名函数。下面以一个阶乘的递归来说明。

```
#Python版本，后面会加上C++版本
#F(f) = f
def F(f,n):
    return 1 if n==0 else n*f(n-1)
#或者用lambda
#F = lambda f,n: 1 if n==0 else n*f(n-1)
#Y不能用lambda，因为Y会调用自己

#Y(F) = f = F(f) = F(Y(F))
def Y(F):
    return lambda n: F(Y(F),n)
a = Y(F)
# 6
print a(3)
```

一些解释：

+ F是伪递归函数，将真正的我们假设的匿名函数作为参数，有性质
F(f)=f.
+ 好了以上是我们的已知条件，为了得到f的间接表达式，我们引入Y函数
使得Y(F) = f
+ 所以有Y(F) = f = F(f) = F(Y(F)) （最终的目标是要用YF的组合表示f），所以很容易就得到了Y(F)的函数表达式为F(Y(F))，而Y不是匿名函数，所以能自身调用(其实感觉这东西没想象中那么玄乎～)，上面的代码也就比较好理解了。我们假设的函数只有一个额外参数n，这完全可以自己添加其他参数，只需稍微修改Y中F的调用。

最后附上一段C++的实现代码：

```
//需要C++11支持
#include <iostream>
#include <functional>
//F(f) = f
int 
F(std::function<int(int)> f, int n)
{
    return n==0 ? 1 : n*f(n-1);
}
//或者
//auto F1 = [](std::function<int(int)> f, int n) {
//    return n==0 ? 1 : n*f(n-1);
//};


//Y(F) = f = F(f) = F(Y(F))
std::function<int(int)>
Y(std::function<int(std::function<int(int)>,int)> F)
{
    return std::bind(F, std::bind(Y,F), std::placeholders::_1);
}

int main(int argc, char *argv[])
{
    auto f = Y(F);
    std::cout << f(3) << std::endl; //6
    return 0;
}
```


