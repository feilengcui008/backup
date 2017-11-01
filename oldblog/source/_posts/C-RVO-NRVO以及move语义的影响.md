title: C++ RVO/NRVO以及move语义的影响
date: 2015-05-09 13:22:37
categories: [编程语言]
tags: [C/C++, 优化]
---

C++返回值优化和具名返回值优化是编译器的优化，在大多数情况下能提高性能，但是却难以受程序员控制。C++11中加入了move语义的支持，由此对RVO和NRVO会造成一定影响。下面以一段代码来说明。

RVO和NRVO在分别在copy/move construct，copy/move assignment八种简单情况，测试条件是g++ 4.8.2和clang++ 3.4，默认优化。

```
#include <iostream>
#include <vector>
#include <string>

struct Test {
    Test()
    {
        std::cout << "construct a Test object" << std::endl;
    }

    Test(const Test&)
    {
        std::cout << "copy construct  a Test object" << std::endl;
    }
    
    Test& operator=(const Test&)
    {
        std::cout << "copy assignment a Test object" << std::endl;
        return *this;
    }

    
    Test(Test&&)
    {
        std::cout << "move construct a Test object" << std::endl;
    }
    

    /*
    Test& operator=(Test &&t)
    {
        std::cout << "move assignment a Test object" << std::endl;
        return *this;
    }
    */

    ~Test()
    {
        std::cout << "destruct a Test object" << std::endl;
    }
};

Test getTest()
{
    return Test();
}

Test getTestWithName()
{
    Test temp;
    return temp;
}

int main()
{
    std::cout << "=============RVO==============" << std::endl; 
    std::cout << "++Test obj rvo for copy construct" << std::endl;
    auto obj1 = getTest();

    std::cout << "--------------" << std::endl;
    std::cout << "++Test obj rvo for move construct" << std::endl;
    auto obj111 = std::move(getTest());

    std::cout << "--------------" << std::endl;  
    std::cout << "++Test obj rvo for copy assignment" << std::endl;
    Test obj11; obj11 = getTest();
  
    std::cout << "--------------" << std::endl;
    std::cout << "++Test object rvo for move assignment" << std::endl;
    Test obj1111; obj1111 = std::move(getTest());
    

    std::cout << "=============NRVO==============" << std::endl; 
    std::cout << "++Test obj nrvo for copy construct" << std::endl;
    auto obj2 = getTestWithName();
    
    std::cout << "--------------" << std::endl;
    std::cout << "++Test obj nrvo for move construct" << std::endl;
    auto obj222 = std::move(getTestWithName());
    
    std::cout << "--------------" << std::endl;
    std::cout << "++Test obj nrvo for copy assignment" << std::endl;
    Test obj22; obj22 = getTestWithName();

    std::cout << "--------------" << std::endl;
    std::cout << "++Test obj nrvo for move assignment" << std::endl;
    Test obj2222; obj2222 = std::move(getTestWithName());

    std::cout << "==============================" << std::endl;
    // std::string s1 = "s1 string move semantics test", s2;
    //std::cout << "++before move s1\t" << s1 << std::endl;
    //s2 = std::move(s1);
    //std::cout << "++after move s1\t" << s1 << std::endl;
    //std::cout << "=============" << std::endl;
    return 0;
}
```

测试结果：

```
=============RVO==============
++Test obj rvo for copy construct
construct a Test object
--------------
++Test obj rvo for move construct
construct a Test object
move construct a Test object
destruct a Test object
--------------
++Test obj rvo for copy assignment
construct a Test object
construct a Test object
move assignment a Test object
destruct a Test object
--------------
++Test object rvo for move assignment
construct a Test object
construct a Test object
move assignment a Test object
destruct a Test object
=============NRVO==============
++Test obj nrvo for copy construct
construct a Test object
--------------
++Test obj nrvo for move construct
construct a Test object
move construct a Test object
destruct a Test object
--------------
++Test obj nrvo for copy assignment
construct a Test object
construct a Test object
move assignment a Test object
destruct a Test object
--------------
++Test obj nrvo for move assignment
construct a Test object
construct a Test object
move assignment a Test object
destruct a Test object
==============================
destruct a Test object
destruct a Test object
destruct a Test object
destruct a Test object
destruct a Test object
destruct a Test object
destruct a Test object
destruct a Test object
```

由此可得出几个简单结论：
1.copy construct本身在RVO和NRVO两种情况下被优化了，如果再加上move反而画蛇添足。
2.加入了move assignment后，默认是调用move assignment而不是copy assignment，可以将move assignment注释后测试。
3.对于RVO和NRVO来说，construction的情况编译器优化得比较好了，加入move语义主要是对于assignment有比较大影响
