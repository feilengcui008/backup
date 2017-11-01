title: Lambda与闭包
date: 2015-05-18 14:35:17
categories: [编程语言]
tags: [闭包, Lambda, C++, Python, Java]
---

本文通过javascript/c++11/java8/python/scala等几种语言对lambda和闭包的支持的对比，探讨下lambda和闭包的区别与联系，以及作用域的trick。

----

在阅读这篇文章前，首先熟悉以下几个概念（有些概念不会谈，只是和本文所谈的lambda和闭包对比理解），摘自维基百科：

```
--Closure--
In programming languages, closures (also lexical closures or function closures) are a technique for implementing lexically scoped name binding in languages with first-class functions. Operationally, a closure is a data structure storing a function[a] together with an environment:[1] a mapping associating each free variable of the function (variables that are used locally, but defined in an enclosing scope) with the value or storage location the name was bound to at the time the closure was created.[b] A closure—unlike a plain function—allows the function to access those captured variables through the closure's reference to them, even when the function is invoked outside their scope.

--lexical scope(static scope)--
With lexical scope, a name always refers to its (more or less) local lexical environment. This is a property of the program text and is made independent of the runtime call stack by the language implementation. Because this matching only requires analysis of the static program text, this type of scoping is also called static scoping

--dynamic scope--
With dynamic scope, a global identifier refers to the identifier associated with the most recent environment, and is uncommon in modern languages.[4] In technical terms, this means that each identifier has a global stack of bindings. Introducing a local variable with name x pushes a binding onto the global x stack (which may have been empty), which is popped off when the control flow leaves the scope. Evaluating x in any context always yields the top binding. Note that this cannot be done at compile-time because the binding stack only exists at run-time, which is why this type of scoping is called dynamic scoping.

--anonymous function(common lambda expression)--
In computer programming, an anonymous function (also function literal or lambda abstraction) is a function definition that is not bound to an identifier. Anonymous functions are often:[1]
  -passed as arguments to higher-order functions, or
  -used to construct the result of a higher-order function that needs to return a function.

--Lambda calculus--
Lambda calculus (also written as λ-calculus) is a formal system in mathematical logic for expressing computation based on function abstraction and application using variable binding and substitution.

Lambda expressions are composed of
-variables v1, v2, ..., vn, ...
-the abstraction symbols lambda 'λ' and dot '.'
-parentheses ( )

The set of lambda expressions, Λ, can be defined inductively:
-If x is a variable, then x ∈ Λ
-If x is a variable and M ∈ Λ, then (λx.M) ∈ Λ
-If M, N ∈ Λ, then (M N) ∈ Λ
-Instances of rule 2 are known as abstractions and instances of rule 3 are known as applications.

```

----

关于lambda（这里具体指匿名函数，而不是lambda calculus）与闭包的关系，我自己的理解主要是：
1、闭包实现可以通过类，函数实现，而匿名函数可以用来更方便地实现函数闭包，但通常比嵌套函数实现闭包局限更大，比如后面会会提到：
    
+ python的lambda实现的闭包不能使用statement,需返回expression(value) 
    如:lambda : a if a>0 else -a
    
+ 但是java的lambda提供了statement和expression两种
    如:()->value,()->{return value;}
+ 其他

2、闭包主要是对作用域的trick，与编程语言本身采用的lexical scope或者dynamic scope有关，两个非常重要的点是闭包中的操作对局部变量的获取方式（是否存在side-effect），值捕获(immutable，比如python2、python3不用nonlocal、java8、c++使用[=]capture、scala等)还是引用捕获(mutable，比如javascript、python3nonlocal、c++使用[&]capture等)，这些操作是交给程序员（比如C++），还是留给compiler？

3、匿名函数通常在直接支持function为first-class的编程语言中用起来更顺畅，作为返回值或者参数传给高阶函数，尤其是动态语言如Scheme或者Python以及支持类型推导的静态语言如scala和c++。像java，虽然有java.util.function等包对函数式编程支持，但是没有类型推导，用起来还是稍显麻烦。
比如:
    
+ python 
f = lambda x:x+1
+ scala 
val f = {a => a+1}
+ c++11   
auto f = []()->void{return []{};}()
+ 而java:   
Supplier<Integer> f = (x)->x+1;
Supplier<Integer> f1 = (x)->{return x+1;}

4、闭包实质上是程序员对作用域的控制与改变，通过一定的trick来达到自己需求的变量生命周期，从而实现一些有意思的功能。如果想深入匿名函数相关，还得好好学习functional program，以及lambda calculus。

----

### 下面针对javascript、python、java、c++、scala具体举例：
（注：下文的side-effect指修改局部变量，不包括IO等）

#### javascript的lambda匿名函数和闭包：
值得注意的地方：
1、javascript中，闭包内函数inner capture局部变量是先在与
inner同一作用域中查找，不管变量的定义代码是在inner定义之上还是之下，只需要在同一作用域，这一点和python的nested function闭包类似，不过和c++就不同。
2、javascript不支持显示的函数式编程的expression，需要显示return，返回值，而且匿名函数里面是statement而不是expression，这一点与函数式语言像scala，python不同。
3、javascript支持闭包side-effect
```
//javascript anonymous function closure can direct change the local vars
	var outer = function(){
		var a = 0;
		return (function(){
			//support lambda statements not direct support lambda expressions,need return explicitly 
			a++;
			console.log(a);
			console.log(this);
			return 1212; //explicit return value
			//1212  //will not cause error,but also will not be returned	
		});
	};
	var inner = outer();
	var res = inner(); //1
	inner(); //2
	console.log(res); // 1212

	var outer1 = (function(){
		var a = 12;
		var func = function(){
			a++;
			console.log(a);
		};	
		a = 1222; //notice the scope of javascript,similar to python
		return func;
	});
	var inner1 = outer1();
	inner1(); //1223
	inner1(); //1224
```

#### python的lambda和闭包：
值得注意的地方：
1、python匿名函数体是expression，不能有statement，通常返回值（value）
2、闭包内部函数对局部变量的捕获与前面javascript类似
3、python2不支持对局部变量的修改，而python3引入nonlocal关键字后能支持闭包的side-effect。
```
#python anonymous function closure can not change the local vars
#support lambda expressions not support lambda statements
def outer():
	a = 1
	return lambda:a if a>0 else -a
print(inner())

#pyyhon3 add nonlocal to allow closure change local vars
def outer1():
	a = 1
	def inner1():
		nonlocal a
		a = a+2;
		return a
	a = 3 #scope similar to javascript
	return inner1
inner1 = outer1()
print(inner1())
print(inner1())

#before nonlocal,we can ref local vars
def outer2():
	a = 1
	def inner2():
		print(a)
	return inner2
inner2 = outer2()
inner2()
```

#### java中的lambda和闭包：
值得注意的地方：
1、java的lambda函数体支持statement和expression
2、java没有提供对局部变量的修改方式（不支持side-effect避免concurrency下的问题）
3、由于java没有nested function，可以使用内部类、局部类模拟
ref:
http://www.oracle.com/webfolder/technetwork/tutorials/obe/java/Lambda-QuickStart/index.html#section4
http://stackoverflow.com/questions/7367714/nested-functions-in-java
https://docs.oracle.com/javase/8/docs/api/java/util/function/package-summary.html
http://www.lambdafaq.org/what-are-the-reasons-for-the-restriction-to-effective-immutability/
```
import java.util.function.*;

class Test{
    public static void main(String args[])
    {
        Test t = new Test();
        Supplier<Integer> f = t.outer();
        System.out.println(f.get()); //1
    }
    Supplier<Integer> outer()
    {
        //Predicate<T>
        //Consumer<T>
        //Supplier<R>
        //Function<T,R>

        int a = 1;
        //lambda expressions way
        //return ()->a+1;

        //lambda statements way
        return ()->{System.out.println(a+1);return a;};
        
        //error a should be immutable
        //return ()->{a++;return a;};
    }
}
```

#### c++的lambda和闭包
值得注意的点：
1、c++将局部变量的capture方式交给了程序员capture by value and capture by reference
2、同java一样没有直接对nested function的支持，如std::function<void(void)> f3的使用是很容易出错的，所以把闭包side-effect交给程序员管理增强灵活性的同时也很容易导致问题。
3、注意f2的结果0，而不是12，c++匿名函数的捕获只能捕获匿名函数定义代码之前的，跟js和python不同。
```
#include <iostream>
#include <functional>

std::function<void(void)> returnFunc()
{
	int x = 0;
	std::function<void(void)> f = [=]()->void{ std::cout << x << std::endl; };
	x = 12;
	return f;
}

std::function<void(void)> returnFunc1()
{
	int x = 0;
	//不能保存变量x
	std::function<void(void)> f = [&]()->void{ x++; std::cout << x << std::endl; };
	x = 12;
	return f;
}

int _tmain(int argc, _TCHAR* argv[])
{
	//Solution::test();
	

	int a = 1;
	
	auto f = [=]()->int{return a; };
	a = 2;
	std::cout << f() << std::endl; //1 but not 2
	

	auto f1 = [&]()->int{a = 3; return a; };
	std::cout << f1() << std::endl; //3

	std::function<void(void)> f2 = returnFunc();
	f2(); //0 not 12
	f2(); //0 not 12

	std::function<void(void)> f3 = returnFunc1();
	f3(); //-858993459 not 1
	f3(); //-858993459 not 2

	return 0;
}
```

#### scala的lambda和闭包
由于函数式编程语言本身对first-class function、imutable、high-order function、type-inference等较好的支持，所以在函数式语言中使用lambda和闭包很顺畅。
值得注意的几点：
1、从test1可以看出，scala捕获局部变量的方式与js和python类似
2、从test2可以看出，scala支持闭包变量的保留，与js和python类似，而不同于c++

```
object YCombinator {
	def main(args:Array[String]) = {
	
			test1() //3 not 2

			var f = test2()
			println(f()) //1
			println(f()) //2	
			println(f()) //3

		}

	def test1() = {
		var x = 1
		val f = ()=>{x=x+1;x}
		x = 2
		println(f()) //3 not 2
	}

	def test2():()=>Int = {
    	var a = 0
    	var b = 1
    	() => {
    		println(b+"---") 
        	val t = a
        	a = b
        	b = t + b
        	b
    	}
    }
}

```

### 总结
闭包和lambda的区别和联系在开头已经说过了，不再赘述。以上各种语言对闭包的支持大致可以归纳如下：

+ javascript天生支持side-effect的闭包，而匿名函数的函数体支持statement，不直接支持表达式返回值，需显示返回值。局部变量的capture最近作用域是与闭包内部函数体同一级，而部分变量定义在之前还是之后。
+ python3中引入nonlocal关键字后支持闭包的side-effect，匿名函数体不支持statement，表达式直接返回值，nested function闭包内的函数体支持statement。局部变量的capture最近作用域与javascript类似。
+ java不支持闭包side-effect，匿名函数体支持statement，或者直接表达式返回值。
+ c++将匿名函数闭包的side-effect交给程序员控制，函数体不支持表达式直接返回，局部变量的capture最近作用域为闭包内部函数同一作用域且位于内部函数之前。
+ scala支持闭包的side-effect，匿名函数体支持statement和表达式，局部变量的capture最近作用域与javascript和python类似，基本提供了动态语言中使用lambda和闭包的方便性。

