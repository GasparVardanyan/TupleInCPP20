---
title: "Implementing a tuple in C++20. Deep dive."
date: 2026-04-28T17:26:31+04:00
---

## Storing values in the inheritance hierarchy

First, let's understand how a single struct can store a variable amount of data
of different types, all defined at compile time. When the type is fixed, we use
arrays to avoid using different names for each data field. But now the types
are arbitrary. The easiest solution is to store data in the inheritance
hierarchy where at each level we store a distinct member:
```cpp
# include <iostream>

struct S1 {
	int value = 10;
};

struct S2 : S1 {
	double value = 2.3;
};

int main () {
	S2 s;
	std::cout << s.value << std::endl;
	std::cout << static_cast <S1 &> (s).value << std::endl;
}
```
The output is:
```
2.3
10
```

This is member hiding, not something like overloading. Both value
members are separately stored in the S2 class, static_cast helps
to access the base class's value member. S2 being inherited from S1
[have](https://en.cppreference.com/cpp/language/derived_class#Syntax)
an S1 *subobject* inside it which
[stores](https://en.cppreference.com/index.php?title=cpp/language/object#Subobjects)
S2's *subobjects*.

Let's see what happens here:
```cpp
# include <iostream>

int main ()
{
    struct S1 { int x; };
    struct S2 : S1 {}; // S2 has S1 subobject
    S2 s2 {}; // S2 { S1 { x } }
    s2.x = 10;
    std::cout << s2.x << std::endl;
}
```
Here since S2 has only one x member in its subobject hierarchy, S2::x isn't
ambiguous, the compiler successfully finds the x subobject.

Let's see what happens when the most derived class has multiple subobjects
with the same name:
```cpp
# include <iostream>

int main () {
    struct A { int a = 1; };
    struct X : A {}; // X have A subobject
    struct Y : A {}; // Y have A subobject
    struct AA : X, Y {};    // AA has X and Y subobjects each of which has
                            // a distinct A subobject

    AA aa; // AA { X { A { a } }, Y { A { a } } }
    // aa.A::a = 0; // error1 : Ambiguous conversion from derived class 'AA' to base class 'A':
                    //          struct AA -> X -> A
                    //          struct AA -> Y -> A
    aa.X::a = 1;
    aa.Y::a = 2;
    std::cout << aa.X::a << aa.Y::a << std::endl;

    // aa.a = 3;	// error2 :  Non-static member 'a' found in multiple base-class subobjects of type 'A':
                    //           struct AA -> X -> A
                    //           struct AA -> Y -> A

    // aa.X::A::a = 4; // error1
    // static_cast <A &> (aa).a = 3; // error1
    // static_cast <X::A &> (aa).a = 3; // error1

    static_cast <X &> (aa).a = 3;
    static_cast <Y &> (aa).a = 4;

    std::cout << static_cast <X &> (aa).a << static_cast <Y &> (aa).a << std::endl;
}
```
Output:
```
12
34
```

Here AA have X and Y base-class subobjects, each of which have a distinct
A subobject. Access to a subobject through aa itself is ambiguous, because
AA have two **int a** subobjects in its subobject hirarchy and the access
is ambigious. But since both X and Y have single **int a** subobjects,
access expressions like **aa.X::a** and **static_cast <Y &> (aa)** are well
defined and evaluate to the appropriate integer.

If you code with NeoVim, there is an [extension](https://github.com/J-Cowsert/classlayout.nvim)
which helps visualize class object layouts. In case of the AA class it is:
```
Class Layout: AA
========================================
         0 | struct AA
         0 |   struct X (base)
         0 |     struct A (base)
         0 |       int a
         4 |   struct Y (base)
         4 |     struct A (base)
         4 |       int a
           | [sizeof=8, dsize=8, align=4,
           |  nvsize=8, nvalign=4]
```

An interesting case is when we have virtual inheritance:
```cpp
# include <iostream>

int main () {
	{
		struct A { int a = 1; };
		struct X : virtual A {};
		struct Y : A {};
		struct AA : X, Y {};

		AA aa; // { AA, X, virtual A, Y, A }
		// aa.A::a = 0; // error1
		aa.X::a = 1;
		aa.Y::a = 2;
		aa.a = 3; // error2

		std::cout << aa.X::a << aa.Y::a << std::endl;
	}

	std::cout << "====================" << std::endl;

	{
		struct A { int a = 10; };
		struct X : virtual A {};
		struct Y : virtual A {};
		struct AA : X, Y {};

		AA aa; // { AA, X, virtual A, Y }
		std::cout << aa.A::a << aa.X::a << aa.Y::a << aa.AA::a << aa.a << std::endl;
		aa.A::a = 0;
		std::cout << aa.A::a << aa.X::a << aa.Y::a << aa.AA::a << aa.a << std::endl;
		aa.X::a = 1;
		std::cout << aa.A::a << aa.X::a << aa.Y::a << aa.AA::a << aa.a << std::endl;
		aa.Y::a = 2;
		std::cout << aa.A::a << aa.X::a << aa.Y::a << aa.AA::a << aa.a << std::endl;
		aa.a = 3;
		std::cout << aa.A::a << aa.X::a << aa.Y::a << aa.AA::a << aa.a << std::endl;
	}
}
```
Output:
```
12
====================
1010101010
00000
11111
22222
33333
```

The most-derived object contains only one A subobject if and only if either
A appears exactly once in the inheritance hierarchy, virtual or non virtual,
or every inheritance path leading to A is virtual with respect to A.

Furthermore consider the complete inheritance graph of a class AA.  For any
base type AX, conceptually flatten the graph so that every inheritance path
to AX becomes a direct occurrence in a list.  Then:
* every non-virtual occurrence of AX remains a distinct AX subobject;
* all occurrences of AX reached through virtual inheritance are merged
  into a single shared AX subobject.
The resulting set exactly describes how many AX subobjects physically reside
inside an object of type AA.

In the first case in the example above, we had two **A** subobjects in **AA**:
one through virtual inheritance and one through regular inheritance, but in the
second case, since all inheritance paths leading to **A** were virtual with
respect to **A**, they are merged into a single **A** subobject.

Furthermore directly virtually inherited classes are initialized only in the most
derived class:

```cpp
# include <iostream>

struct A {
	int a;

	A () : a (0) {
		std::cout << "A initialized with 0" << std::endl;
	}

	A (int param) : a (param) {
		std::cout << "A initialized with param=" << param << std::endl;
	}
};

struct B1 : A {
	int b;

	B1 (int param) : A (param), b (param) {}
};

struct C1 : B1 {
	int c;

	C1 (int param) : B1 (param), c (param) {}
};

struct B2 : virtual A {
	int b;

	B2 (int param) : A (param), b (param) {}
};

struct C2 : B2 {
	int c;

	C2 (int param) : B2 (param), c (param) {}
};

int main () {
	C1 c1 (42);
	std::cout << c1.c << " " << c1.b << " " << c1.a << std::endl;
	C2 c2 (42);
	std::cout << c2.c << " " << c2.b << " " << c2.a << std::endl;
    B1 b1 (42);
	std::cout << b1.b << " " << b1.a << std::endl;
    B2 b2 (42);
	std::cout << b2.b << " " << b2.a << std::endl;
}
```
The output is:
```
A initialized with param=42
42 42 42
A initialized with 0
42 42 0
A initialized with param=42
42 42
A initialized with param=42
42 42
```
In case of C1-B1, everything is obvious: C1's parametrized constructor takes
an integer, passes it to B1's parametrized constructor and initializes its
member integer c. Then B1's parametrized constructor passes the value to
A's parametrized constructor and initializes its member integer b. Then
A's parametrized constructor initializes its member integer a.

In case of C2-B2, the only difference is that B2 inherits A virtually.  Since A
is virtually inherited, it must be initialized in the most derived class:
C2. C2 doesn't pass the value to A's constructor. Even though C2 calls B2's
parametrized constructor, which at first glance seems to call A's parametrized
constructor, it doesn't, so A's default constructor is called.

In case of **b2**, **B2** is the most derived class so the call to A's
parametrized constructor gets evaluated.

So far we've got the S2 class which allows to store two distinct members of
different types, and the types and values are fixed in the class. Let's make
types arbitrary and add value initializers:
```cpp
# include <iostream>

template <typename T>
struct S1 {
	T value;

	S1 (const T & t)
		: value (t)
	{}
};

template <typename T, typename U>
struct S2 : S1 <T> {
	U value;

	S2 (const T & t, const U & u)
		: S1 <T> (t)
		, value (u)
	{}
};

int main () {
	S2 s (10, 2.3);
	std::cout << s.value << std::endl;
	std::cout << static_cast <S1 <int> &> (s).value << std::endl;
}
```
Here we store different types of values, but the number of values we store
is fixed. We'll make the number of values dynamic later. This works for a
simple case like **T=int** and **U=double**, but we have a couple of problems.

**The first problem** is that when we try to initialize S2 with a string
literal like:
```cpp
S2 s (10, "abc");
```
The type of "abc" is **const char \[4\]** and in the constructor of S2 we are
trying to initialize a char array with another array which is forbidden in C++.

**The second problem** is **const T &**. We are always copy-constructing
the members. This is a bad practice in general because in some cases we can
move the data instead of copying which is faster. Furthermore S2 will fail
to construct when we use a non-copyable type, for example std::unique_ptr:

```cpp
S2 s (10, std::make_unique <int> (10));
```

When we initialize s like this:
```cpp
S2 s (10, "abc");
```
The compiler
[deduces](https://en.cppreference.com/cpp/language/class_template_argument_deduction)
the template types for us. The call above is equivalent to:
```cpp
S2 <int, const char [4]> (10, "abc");
```
The solution to the first problem is to add a **deduction guide** to help
the compiler to deduce the template types better for us. After the definition
of S2 we have to add:
```cpp
template <typename T, typename U>
S2 (T, U) -> S2 <T, U>;
```
When we don't explicitly add this deduction guide, the compiler generates one
for us based on the constructor signature:
```cpp
template <typename T, typename U>
S2 (const T &, const U &) -> S2 <T, U>;
```
In C++ string literals are arrays of const chars [by
default](https://en.cppreference.com/cpp/language/string_literal).
Template argument deduction for deduction guides
work like it works for function calls. When template
argument deduction happens for a templated function call,
[these](https://en.cppreference.com/cpp/language/template_argument_deduction#Deduction_from_a_function_call)
rules apply.

These rules specify that if the **parameter** type isn't a
reference type and the **argument** type is an array type, the argument type
is replaced by the pointer type obtained from array-to-pointer conversion.
The implicitly generated deduction guide uses the constructor's signature
hence uses const references. Our deduction guide uses non-reference types
so array to pointer decay happens.

Now let's solve the second problem.

## Perfect forwarding

The solution to the second problem is to use perfect forwarding:
```cpp
# include <iostream>
# include <memory>
# include <type_traits>
# include <utility>

template <typename T>
struct S1 {
	T value;

	template <typename T1>
	S1 (T1 && t)
		: value (std::forward <T1> (t))
	{}
};

template <typename T, typename U>
struct S2 : S1 <T> {
	U value;

	template <typename T1, typename U1>
	S2 (T1 && t, U1 && u)
		: S1 <T> (std::forward <T1> (t))
		, value (std::forward <U1> (u))
	{}
};

template <typename T, typename U>
S2 (T, U) -> S2 <T, U>;

int main () {
	S2 s (10, std::make_unique <int> (10));
	std::cout << * s.value.get () << std::endl;
	std::cout << static_cast <S1 <int> &> (s).value << std::endl;
}
```
To understand what std::forward does, we need to understand the reference
collapsing rules. In C++20 we have two types of references: lvalue references
and rvalue references. The logic behind them is strictly tied to the value
categories of expressions.

Value category is a property of an expression. There are five value categories:
three primary and two extended. Lvalue, xvalue (expiring value) and prvalue
(pure rvalues) are the primary value categories. Lvalues and xvalues together
are called glvalues (generic lvalues). Xvalues and prvalues together are
called rvalues. xvalues are both glvalues and rvalues at the same time.

C++11 introduced these value categories with two main properties in
mind: whether the expression refers to an object having identity beyond
the expression's evaluation or not and whether we can **steal**/**move**
from it or not.

Lvalues are expressions which evaluate to an object in memory which exists
beyond the lifetime of that expression. In other words, lvalues are expressions
which refer to an object with identity. We can't move/steal from lvalues without
casting them to xvalues. For example, an expression which names a variable or
object member is an lvalue. In contrast, when we call a function returning
an int, the call expression evaluates to a temporary object containing the
returned value which doesn't exist before or after the evaluation of the
expression, hence this expression isn't an lvalue. This holds when we return
non-reference types. For functions returning references, the rules change.

Prvalues are the opposite of lvalues: they don't have identity, but we can steal
from them. For example, a call to a function returning a non-reference
type such as int is a prvalue expression.

Xvalues are the expressions which both have identity and can be moved from.

These aren't the exact rules, I'm trying to keep things simple and beginner
friendly.

To understand what it means to steal/move from an object and why we do it at
all, let's consider this example:
```cpp
# include <iostream>

class IntCell
{
public:
	explicit IntCell (int initialValue = 0)
		: m_storedValue (new int {initialValue})
	{
		std::cout << "ctor" << std::endl;
	}

	~IntCell () {
		delete m_storedValue;
		std::cout << "dtor" << std::endl;
	}

	IntCell (const IntCell & o)
		: m_storedValue (new int {* o.m_storedValue})
	{
		std::cout << "copy ctor" << std::endl;
	}

	IntCell & operator= (const IntCell & o) {
		if (this != & o) {
			* m_storedValue = * o.m_storedValue;
		}
		std::cout << "copy assign" << std::endl;
		return * this;
	}

	int read () const {
		return * m_storedValue;
	}

	void write (int x) {
		* m_storedValue = x;
	}

private:
	int * m_storedValue;
};

IntCell foo () {
	IntCell c;
	c.write (22);
	return c;
}

int main () {
	IntCell c (foo ());
	std::cout << "..." << std::endl;
}
```
When we disable the copy elision optimization of the compiler, for example with
the -fno-elide-constructors option of clang, the output will be:
```
ctor
copy ctor
dtor
...
dtor
```
Here **foo** constructs an **IntCell** object, returns it, we copy it to the
variable **c** in the **main** function then the returned **IntCell** object
gets destroyed. When the **main** function ends, **c** destroys too. When
we initialize **c** with **foo**'s returned value, the copy constructor of
**IntCell** allocates a new int with the value of the returned **IntCell**
object's **m_storedValue** member. So we have two int allocations on the
heap. But since after the call of **foo** we copy the returned object and it
gets destroyed, we could just take its already allocated **m_storedValue**
member instead of copying. That would be one (actually two) pointer assignments
instead of a new allocation plus initialization of a member. In case of
classes with large allocated data, for example a vector of thousands of ints,
or even a vector of a custom type having its own resources, the performance
difference becomes significant. C++11 introduced rvalue references which
help to avoid this unnecessary copying.
* lvalue references to non-consts can be initialized only with lvalue
expressions.
* rvalue references to non-consts can be initialized only with rvalue
expressions.

Rvalue references are a better match to take prvalues in function overload
resolution:
```cpp
IntCell foo () {
	IntCell c;
	c.write (22);
	return c;
}

void f (IntCell &) {
	std::cout << "foo1" << std::endl;
}

void f (const IntCell &) {
	std::cout << "foo2" << std::endl;
}

void f (IntCell &&) {
	std::cout << "foo3" << std::endl;
}

int main () {
	IntCell c (foo ());
	f (foo ());
}
```
The expression **foo ()** is prvalue. Here the third implementation of f will
be selected since it accepts an rvalue reference. If we remove the third
implementation, the second one will be matched: lvalue references to constants
can be initialized with rvalues. But if we remove the second overload too,
we'll have an error because we can't initialize lvalue references to non-consts
with temporaries. [This](https://www.youtube.com/watch?v=d5h9xpC9m8I)
is a great video explaining value categories much deeper.

Now we can change the implementation of the IntCell class to handle temporaries
better:
```cpp
# include <iostream>
# include <utility>

class IntCell
{
public:
	explicit IntCell (int initialValue = 0)
		: m_storedValue (new int {initialValue})
	{
		std::cout << "ctor" << std::endl;
	}

	~IntCell () {
		delete m_storedValue;
		std::cout << "dtor" << std::endl;
	}

	IntCell (const IntCell & o)
		: m_storedValue (new int {* o.m_storedValue})
	{
		std::cout << "copy ctor" << std::endl;
	}

	IntCell (IntCell && o) noexcept
		: m_storedValue (o.m_storedValue)
	{
		o.m_storedValue = nullptr;
		std::cout << "move ctor" << std::endl;
	}

	IntCell & operator= (const IntCell & o) {
		if (this != & o) {  // this is the generic copy and swap technique often
							// used with a custom swap overload
							// here we avoid manually repeating the copying
							// instructions used in the copy constructor
			IntCell copy = o;
			std::swap (* this, copy);
		}
		std::cout << "copy assign" << std::endl;
		return * this;
	}

	IntCell & operator= (IntCell && o) noexcept {
		// std::swap (* this, o);	// will go into infinite recursion if swap is
									// implemented with 3 move assignments
		std::swap (m_storedValue, o.m_storedValue); // member-wise swap
		std::cout << "move assign" << std::endl;
		return * this;
	}

	int read () const {
		return * m_storedValue;
	}

	void write (int x) {
		* m_storedValue = x;
	}

private:
	int * m_storedValue;
};

IntCell foo () {
	IntCell c;
	c.write (22);
	return c;
}

int main () {
	IntCell c (foo ());
	std::cout << "..." << std::endl;
}
```
Here the output (with copy elision disabled) will be:
```
ctor
move ctor
dtor
...
dtor
```
And now we do 1 allocation of int on the heap. The constructor taking an rvalue
reference is called move constructor. Here instead of allocating a new int and
initializing it with the other object's m_storedValue, we take the object's
member directly. Notice that we assign the other object's m_storedValue to
nullptr since it's about to destroy and otherwise its destructor would free
the memory allocated for m_storedValue.

The copy and move constructors and assignment operators together with the
destructor are called Big Five. It's a good practice to either manually
implement big five or implement neither and use the implicitly generated
defaults. See [this](https://en.cppreference.com/cpp/language/rule_of_three)
for more info.

The move constructor and the move assignment typically do only pointer
assignments while the copy constructor and the copy assignment operator
do object construction and some other stuff. The object construction
itself can throw an exception, for example because of insufficient memory
resources. Pointer assignments can't throw an exception. When we declare a
function in C++ by default it's allowed to throw exceptions. To explicitly
specify that the function doesn't throw an exception, we use the noexcept
specifier. When STL containers like std::vector reallocate the data, they use
the move constructor/assignment instead of the copy constructor/assignment only
when the move constructor/assignment is explicitly marked **noexcept**. The
reason is simple: when you move the data and it throws, you've lost your
data. The exception can happen in the middle of the move process and invalidate
your data. When you copy the data and it throws, you've failed to move your
data to the reallocated storage, but your existing data remains valid.

### Template specialization

To support arbitrary number of members of arbitrary types, we need to understand
how template specialization, parameter packs and template recursion work. We
need template specialization also to demonstrate some examples about perfect
forwarding, so let's try to understand how template specialization works
with the example of std::decay_t since we need some constructs used in its
implementation.

std::decay_t is defined like:
```cpp
namespace std {
template <typename T>
using decay_t = typename decay <T>::type;
}
```
where std::decay is a specialized templated struct.
What std::decay <T> does is:
* If T is "array of U" or reference to it, the member typedef type is U\*.
* Otherwise, if T is a function type F or reference to one, the member typedef
type is std::add_pointer<F>::type.
* Otherwise, the member typedef type is
std::remove_cv<std::remove_reference<T>::type>::type.

To not complicate things further we'll skip the function case and implement
a mini decay, but first we have to understand how the template specialization
works.

```cpp
# include <iostream>

template <typename T>
struct S {
	static inline const char * value = "generic";
};

template <>
struct S <int> {
	static inline const char * value = "int";
};

template <>
struct S <double> {
	static inline const char * value = "double";
};

int main () {
	std::cout << S <int>::value << std::endl;
	std::cout << S <double>::value << std::endl;
	std::cout << S <float>::value << std::endl;
}
```
Output:
```
int
double
generic
```
The idea is that we can have different implementations of the same templated
struct based on the template parameters. Here the **inline** keyword is
necessary to be able to initialize the static members directly inside structs.

These all match the generic specialization since none of them is int or double:
```cpp
std::cout << S <const int>::value << std::endl;
std::cout << S <volatile int>::value << std::endl;
std::cout << S <const volatile int>::value << std::endl;
std::cout << S <int &>::value << std::endl;
std::cout << S <int &&>::value << std::endl;
```
We can specialize templates based on reference category and const volatile
qualifiers:
```cpp
# include <iostream>

template <typename T>
struct S {
	static inline const char * value = "generic";
};

template <typename T>
struct S <const T> {
	static inline const char * value = "const";
};

template <typename T>
struct S <volatile T> {
	static inline const char * value = "volatile";
};

template <typename T>
struct S <const volatile T> {
	static inline const char * value = "const volatile";
};

template <typename T>
struct S <T &> {
	static inline const char * value = "lvalue reference";
};

template <typename T>
struct S <T &&> {
	static inline const char * value = "rvalue reference";
};

int main () {
	std::cout << S <int>::value << std::endl;
	std::cout << S <const int>::value << std::endl;
	std::cout << S <volatile int>::value << std::endl;
	std::cout << S <const volatile int>::value << std::endl;
	std::cout << S <int &>::value << std::endl;
	std::cout << S <int &&>::value << std::endl;
}
```
The output is:
```
generic
const
volatile
const volatile
lvalue reference
rvalue reference
```
The compiler selects the specialization that is the most specialized.

For example here:
```cpp
# include <iostream>

template <typename T>
struct S { // primary template
	static inline const char * value = "generic";
};

template <typename T>
struct S <volatile T> { // specialized template
	static inline const char * value = "volatile";
};

template <typename T>
struct S1 { // primary template
	static inline const char * value = "generic";
};

template <typename T>
struct S1 <const T> { // specialized template
	static inline const char * value = "const";
};

int main () {
	std::cout << S <int>::value << std::endl;
	std::cout << S <const int>::value << std::endl;
	std::cout << S1 <int>::value << std::endl;
	std::cout << S1 <const int>::value << std::endl;
}
```
In the case of S, the primary template matches both int and const int because
T is a type which can be both int and const int. The specialized version
matches neither of them.

In case of S1, the specialization is "more specialized" for const ints
than the primary template: they both match const int, but the specialized
version is a stricter match, because it matches only const types while
the primary template matches both const and non-const types, hence the
specialization is more specialized for const ints.

The interesting thing here is what happens to T within the template. The
template matched const int with the template parameter of type const T,
so T within the template becomes int.

We can drop both const and volatile qualifiers and references with templates.
In all of these cases the struct member type is int:
```cpp
# include <iostream>

template <typename T>
struct S {
	using type = T;
};

template <typename T>
struct S <const T> {
	using type = T;
};

template <typename T>
struct S <volatile T> {
	using type = T;
};

template <typename T>
struct S <const volatile T> {
	using type = T;
};

template <typename T>
struct S <T &> {
	using type = T;
};

template <typename T>
struct S <T &&> {
	using type = T;
};

int main () {
	S <int>::type v1;
	S <const int>::type v2;
	S <volatile int>::type v3;
	S <const volatile int>::type v4;
	S <int &>::type v5;
	S <int &&>::type v6;
}
```
All v1, v2, v3, v4, v5 and v6 variables are of type int. But what happens when
we use **S <const int &>::type**? **const int &** is a reference to const int,
so it's a reference and only then a const. The **struct S <T &>** specialization
gets selected and **S <const int &>::type** becomes **const int**.

Now we can implement separate templates to remove const and volatile qualifiers
and references from types:
```cpp
template <typename T>
struct RemoveCV {
	using type = T;
};

template <typename T>
struct RemoveCV <const T> {
	using type = T;
};

template <typename T>
struct RemoveCV <volatile T> {
	using type = T;
};

template <typename T>
struct RemoveCV <const volatile T> {
	using type = T;
};

template <typename T>
struct RemoveReference {
	using type = T;
};

template <typename T>
struct RemoveReference <T &> {
	using type = T;
};

template <typename T>
struct RemoveReference <T &&> {
	using type = T;
};
```
Now we can use these **type traits** as follows:
```cpp
RemoveCV <int>::type v1;
RemoveCV <const int>::type v2;
RemoveCV <const volatile int>::type v3;
RemoveReference <int>::type v4;
RemoveReference <int &>::type v5;
RemoveReference <int &&>::type v6;
```
All of v1 to v6 are ints.

Furthermore we can convert (decay) arrays to pointers:
```cpp
# include <iostream>
# include <type_traits>

template <typename T>
struct ArrayDecay;

template <typename T, std::size_t S>
struct ArrayDecay <T [S]> {
	using type = T *;
};

template <typename T>
struct ArrayDecay <T []> {
	using type = T *;
};

int main () {
	std::cout << std::is_same_v <ArrayDecay <int [2]>::type, int *> << std::endl;
	std::cout << std::is_same_v <ArrayDecay <const int [2]>::type, const int *> << std::endl;
	std::cout << std::is_same_v <ArrayDecay <int []>::type, int *> << std::endl;
	std::cout << std::is_same_v <ArrayDecay <const int []>::type, const int *> << std::endl;
}
```

The implementation of std::is_same_v is trivial:
```cpp
template <typename, typename>
struct IsSame;

template <typename T, typename U>
struct IsSame {
	static constexpr bool value = false;
};

template <typename T>
struct IsSame <T, T> {
	static constexpr bool value = true;
};

template <typename T, typename U>
inline constexpr bool IsSameV = IsSame <T, U>::value;
```
The IsSame type trait have two specializations. When both types are the same,
the second specialization is more specialized so the value becomes true. When
types are different, the first specialization gets selected where the value
is false. This is because the set of possible T, U combinations the second
specialization matches is a subset of the possible T, U combinations the
first specialization matches, so when the second specialization matches,
it's a stricter, more specialized match.

And now we can implement a mini decay skipping the function case:
```cpp
# include <cstddef>
# include <iostream>
# include <type_traits>



template <typename T>
struct RemoveCV {
	using type = T;
};

template <typename T>
struct RemoveCV <const T> {
	using type = T;
};

template <typename T>
struct RemoveCV <volatile T> {
	using type = T;
};

template <typename T>
struct RemoveCV <const volatile T> {
	using type = T;
};



template <typename T>
struct RemoveReference {
	using type = T;
};

template <typename T>
struct RemoveReference <T &> {
	using type = T;
};

template <typename T>
struct RemoveReference <T &&> {
	using type = T;
};



template <typename T>
struct MiniDecayHelper : RemoveCV <T> {};

template <typename T, std::size_t S>
struct MiniDecayHelper <T [S]> {
	using type = T *;
};

template <typename T>
struct MiniDecayHelper <T []> {
	using type = T *;
};

template <typename T>
struct MiniDecay : RemoveReference <typename MiniDecayHelper <T>::type> {};

template <typename T>
using MiniDecayT = typename MiniDecay <T>::type;



int main () {
	std::cout << std::is_same_v <int, MiniDecayT <int>> << std::endl;
	std::cout << std::is_same_v <int, MiniDecayT <const int>> << std::endl;
	std::cout << std::is_same_v <int, MiniDecayT <volatile int>> << std::endl;
	std::cout << std::is_same_v <int, MiniDecayT <const volatile int>> << std::endl;
	std::cout << std::is_same_v <int, MiniDecayT <int &>> << std::endl;
	std::cout << std::is_same_v <int, MiniDecayT <int &&>> << std::endl;
	std::cout << std::is_same_v <const int, MiniDecayT <const int &>> << std::endl;
	std::cout << std::is_same_v <const int, MiniDecayT <const int &&>> << std::endl;
	std::cout << std::is_same_v <int *, MiniDecayT <int []>> << std::endl;
	std::cout << std::is_same_v <int *, MiniDecayT <int [2]>> << std::endl;
	std::cout << std::is_same_v <const int *, MiniDecayT <const int [2]>> << std::endl;
}
```
**MiniDecayT <int \[2\]>** will be **int \*** and **MiniDecayT <const double>**
will be double.

One more thing, and we'll be able to understand how std::forward works and why
we use it.

### Reference collapsing

C++ doesn't allow taking references to references. When we try to do so, the
references "collapse" to a single reference and we still get a reference to
a non-reference type.
The interesting part here is what happens when we try to take an lvalue
reference to an rvalue reference or itself or vice versa.

Let's see what happens here:
```cpp
# include <iostream>
# include <type_traits>

template <typename T>
struct RefType;

template <typename T>
struct RefType <T &> {
	static inline const char * value = "lvalue reference";
};

template <typename T>
struct RefType <T &&> {
	static inline const char * value = "rvalue reference";
};

int main () {
	std::cout << RefType <int &>::value << std::endl;
	std::cout << RefType <int &&>::value << std::endl;

	std::cout << "====================" << std::endl;

	std::cout << RefType <int &  (&)>::value << std::endl;
	std::cout << RefType <int && (&)>::value << std::endl;
	std::cout << RefType <int &  (&&)>::value << std::endl;
	std::cout << RefType <int && (&&)>::value << std::endl;

	std::cout << "====================" << std::endl;

	std::cout << std::is_same_v <int &  (&), int &> << std::endl;
	std::cout << std::is_same_v <int && (&), int &> << std::endl;
	std::cout << std::is_same_v <int &  (&&), int &> << std::endl;
	std::cout << std::is_same_v <int && (&&), int &&> << std::endl;
}
```
Here we have the templated struct **RefType** which helps to identify the
reference category of the given type. First we test it with obvious examples,
make sure that everything is correct and then analyze "the mixed references"
with the help of it. For example when we write **int & (&&)**, we are
"trying to create an rvalue reference of an lvalue reference of an int".

The output is:
```
lvalue reference
rvalue reference
====================
lvalue reference
lvalue reference
lvalue reference
rvalue reference
====================
1
1
1
1
```
Turns out that when we "create an lvalue reference of a reference" we get an
lvalue reference: if the reference was an rvalue reference, it becomes an
lvalue reference, otherwise it remains an lvalue reference. But "creating an
rvalue reference to a reference" preserves the original reference category.

This is a demonstration of the reference collapsing rules in C++20. The
result we've got is a [rule](https://eel.is/c++draft/dcl.ref#7) in the C++
standard, not a side effect of another rule, so there's nothing to explain
why it works like this.


### Preserving reference categories of function arguments

Why do we even have to "preserve" the reference categories of the function
arguments? Don't they preserve it automatically?

Let's see what happens here:
```cpp
# include <iostream>
# include <type_traits>

template <typename T>
struct RefType {
	static inline const char * value = "generic";
};

template <typename T>
struct RefType <T &> {
	static inline const char * value = "lvalue reference";
};

template <typename T>
struct RefType <T &&> {
	static inline const char * value = "rvalue reference";
};

template <typename T>
const char * testRef (T) {
	return RefType <T>::value;
}

int main () {
	int x = 10;

	std::cout << testRef (static_cast <int &> (x)) << std::endl;
	std::cout << testRef (static_cast <int &&> (x)) << std::endl;
}
```
The output is:
```
generic
generic
```
When we don't explicitly specify the template parameters when calling a
function, template types drop reference-ness. So if we want a templated
function to take a reference we have to either manually specify template
types when calling the function like **testRef <int &> (...)** or rewrite
the function to explicitly take references. The exact rules can be found
[here](https://en.cppreference.com/cpp/language/template_argument_deduction).

As we know we can't initialize an rvalue reference directly with an lvalue
expression (without casting):
```cpp
void foo (int &&) {
}

int main () {
	int x = 10;
	foo (4);
	foo (x); // error
}
```
The second call of foo fails because x being an identifier forms an lvalue
expression and we try to pass it to a function taking an rvalue reference.
We could initialize an lvalue reference with the lvalue expression. In C++
every expression referring to a variable with its identifier is an lvalue
expression no matter the variable type.

This is where templates help: they support reference collapsing:
```cpp
# include <iostream>
# include <type_traits>

template <typename T>
void foo (T &&) {
	if (true == std::is_same_v <int &, T &&>) {
		std::cout << "int &" << std::endl;
	}
	else if (true == std::is_same_v <int &&, T &&>) {
		std::cout << "int &&" << std::endl;
	}
	else {
		std::cout << "other" << std::endl;
	}
}

int main () {
	int x = 10;
	foo (4); // 4 is an expression of rvalue value category
	foo (x); // x is an expression of lvalue value category
	foo (static_cast <int &> (x)); // static_cast <int &> (x) is an expression of lvalue value category
	foo (static_cast <int &&> (x)); // static_cast <int &&> (x) is an expression of xvalue value category
}
```
The output is:
```
int &&
int &
int &
int &&
```

We test T &&, not T, because after reference collapsing the type of the
argument is T &&, not T. In case of rvalue and xvalue expressions being
passed as an argument - 4 and static_cast <int &&> (x) in the example
above - T becomes int. In case of lvalue integer expressions T becomes
int &. When T is int &, reference collapsing happens and T && becomes T &.
Otherwise when T is int, T && becomes int &&.
See [this](https://en.cppreference.com/cpp/language/template_argument_deduction#Deduction_from_a_function_call)
for more info.
We have successfully preserved the reference category of the function argument.

When the function have overloads with both T & and T && parameters, and we call
the function without explicitly specifying the template type parameter, the
usual rules apply:
```cpp
# include <iostream>

template <typename T>
const char * refType (T &) {
	return "lvalue reference";
}

template <typename T>
const char * refType (T &&) {
	return "rvalue reference";
}

int main () {
	int x;

	std::cout << refType (x) << std::endl;
	std::cout << refType (5) << std::endl;

	std::cout << "====================" << std::endl;

	int & lref = x;
	int && rref = 5;

	std::cout << refType (lref) << std::endl;
	std::cout << refType (rref) << std::endl;
	std::cout << refType (static_cast <int &&> (rref)) << std::endl;
}
```
The output is:
```
lvalue reference
rvalue reference
====================
lvalue reference
lvalue reference
rvalue reference
```
Notice that calling **refType (rref)** prints "lvalue reference" despite
rref being an rvalue reference. This is because rref being an identifier
forms an lvalue expression.

Since we can preserve the reference category of the function argument, we can
pass the argument to other function with correct type:
```cpp
# include <iostream>

template <typename T>
const char * refType (T &) {
	return "lvalue reference";
}

template <typename T>
const char * refType (T &&) {
	return "rvalue reference";
}

template <typename T>
void printRefType (T && t) {
	std::cout << refType (static_cast <T &&> (t)) << std::endl;
}

int main () {
	int x;

	printRefType (x);
	printRefType (5);

	std::cout << "====================" << std::endl;

	int & lref = x;
	int && rref = 5;

	printRefType (lref);
	printRefType (rref);
	printRefType (static_cast <int &&> (rref));
}
```
The output is:
```
lvalue reference
rvalue reference
====================
lvalue reference
lvalue reference
rvalue reference
```
Here we use both mechanics described above: a function with two overloads
taking both T & lvalue reference and T && rvalue reference, and a function with
a single implementation taking T &&. In the latter case T && isn't an rvalue
reference, it's called **forwarding reference** and the process of passing
the argument to another function preserving the reference category is called
**perfect forwarding**. In the example above we did it with static_cast.

Notice that here reference collapsing happens before the static_cast is
evaluated, in the angle brackets of the static_cast: when T is an lvalue
reference T && collapses to an lvalue reference, otherwise when T is not a
reference type T && forms an rvalue reference. The expression "t" used in
static_cast is an expression of lvalue type. After static_cast we have an
expression of either lvalue or xvalue category and the correct overload of
the function we're passing the argument gets selected. We do this, because
otherwise the expression "t" would be an expression naming a variable and
hence an lvalue. Remember that reference collapsing isn't a casting between
types despite using static_cast.

In our tuple example - where we used S1 and S2 templates - we've used
std::forward for perfect forwarding.

We have to discuss one more thing
before we move forward and implement std::move and std::forward.

When we write a non-template function inside a templated struct, and the
function uses the struct's template parameter types in its parameter
list, reference collapsing happens when we initialize an object of that
struct type, or when we use that struct directly to call a static method,
reference collapsing happens when we finish describing the type, not when
we call the method:
```cpp
# include <iostream>

template <typename T>
const char * refType (T &) {
	return "lvalue reference";
}

template <typename T>
const char * refType (T &&) {
	return "rvalue reference";
}

template <typename T>
struct S {
	static void printRefType (T && t) {
		std::cout << refType (static_cast <T &&> (t)) << std::endl;
	}
};

int main () {
	S <int &> s1;
	S <int &&> s2;

	int x;
	s1.printRefType (x);
	// s2.printRefType (x); // error

	S <int &>::printRefType (x);
	// S <int &&>::printRefType (x); // error
}
```
Here reference collapsing happens when we define s1 and s2, and when we
describe the type **S <int &>** to access its static method, not when we
call the printRefType method of s1 or s2, or when we call the static method
of **S <int &>**. So in this case reference collapsing doesn't depend on
the arguments we pass and the usual rules apply.

Implementing a tuple we've used std::forward like this:
```cpp
template <typename T, typename U>
struct S2 : S1 <T> {
	U value;

	template <typename T1, typename U1>
	S2 (T1 && t, U1 && u)
		: S1 <T> (std::forward <T1> (t))
		, value (std::forward <U1> (u))
	{}
};
```
Instead of using the struct's template parameters, we've implemented a templated
constructor to have reference collapsing.
This is a complete example of using reference collapsing in constructor:
```cpp
# include <iostream>

template <typename T>
const char * refType (T &) {
	return "lvalue reference";
}

template <typename T>
const char * refType (T &&) {
	return "rvalue reference";
}

template <typename T>
struct S {
	template <typename T2>
	S (T2 && t) {
		std::cout << refType (static_cast <T2 &&> (t)) << std::endl;
	}
};

template <typename T>
S (T) -> S <T>;

int main () {
	int x = 5;

	S s1 (x);
	S s2 (5);

	std::cout << "====================" << std::endl;

	int & lref = x;
	int && rref = 5;

	S s3 (lref);
	S s4 (rref);
	S s5 (static_cast <int &&> (rref));
}
```
The output is:
```
lvalue reference
rvalue reference
====================
lvalue reference
lvalue reference
rvalue reference
```

### std::forward and std::move

Now we can write our implementation of std::forward.
We do perfect forwarding either with static_cast or std::forward from a
function accepting a forwarding reference. Remember that the function's
template type parameter is being deduced either as an lvalue reference when
we pass an lvalue expression to that function or as a non-reference type when
we pass an rvalue expression:
```cpp
# include <iostream>
# include <utility>

template <typename T>
struct RefType {
	static inline const char * value = "generic";
};

template <typename T>
struct RefType <T &> {
	static inline const char * value = "lvalue reference";
};

template <typename T>
struct RefType <T &&> {
	static inline const char * value = "rvalue reference";
};

template <typename T>
const char * refType (T &) {
	return "lvalue reference";
}

template <typename T>
const char * refType (T &&) {
	return "rvalue reference";
}

template <typename T>
void printRefType (T && t) {
	std::cout << refType (static_cast <T &&> (t)) << " - " << RefType <T>::value << std::endl;
	std::cout << '\t' << refType (std::forward <T> (t)) << std::endl;
}

int main () {
	int x;

	printRefType (x);
	printRefType (5);

	std::cout << "====================" << std::endl;

	int & lref = x;
	int && rref = 5;

	printRefType (lref);
	printRefType (rref);
	printRefType (static_cast <int &&> (rref));
}
```
Output:
```
lvalue reference - lvalue reference
		lvalue reference
rvalue reference - generic
		rvalue reference
====================
lvalue reference - lvalue reference
		lvalue reference
lvalue reference - lvalue reference
		lvalue reference
rvalue reference - generic
		rvalue reference
```


When we've used std::forward:
* We've passed the variable **t** directly as an lvalue expression without
reference collapsing with static_cast, hence our custom forward implementation
must accept an lvalue reference, not a forwarding reference. From the
reference collapsing rules remember that **T &** is always an lvalue reference.
* We've explicitly set the template type parameter to **T**, which is either
an lvalue reference or a non-reference type based on the reference category
of the expression passed to the printRefType function, hence this is how
std::forward knows the correct value category to evaluate to, which is **T &&**.

The implementation is trivial:
```cpp
template <typename T>
T && Forward (T & t) {
	return static_cast <T &&> (t);
}
```
Inside the Forward function the value category of the expression "t" is
always an lvalue, the only way we know the value category of the expression
passed to Forward is based on the template type's reference-ness. And after
all calling Forward with an rvalue expression will fail since Forward accepts
an lvalue reference which can't be initialized with an rvalue expression, so we
have to make the distinction of lvalue and rvalue arguments outside the Forward
function.

Here static_cast handles the case of passing an lvalue expression denoting an
rvalue reference to the Forward call:
```cpp
int x;
int && y = static_cast <int &&> (x);
Forward <int &&> (y);
```

std::forward is implemented to handle [these use
cases](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2009/n2951.html):
* A: Should forward an lvalue as an lvalue.
* B: Should forward an rvalue as an rvalue.
* C: Should not forward an rvalue as an lvalue.
* D: Should forward less cv-qualified expressions to more cv-qualified
expressions.
* E: Should forward expressions of derived type to an accessible, unambiguous
base type.
* F: Should not forward arbitrary type conversions.

Our Forward implementation is designed the use case **A** in mind.

To support rvalue expressions too, we have to overload our Forward
implementation:
```cpp
template <typename T>
T && Forward (T && t) {
	return static_cast <T &&> (t);
}
```
This would work if we didn't specify the template type parameter
explicitly when calling Forward: **T &&** would be an rvalue reference,
not a forwarding reference, because we have distinct overloads of Forward
to accept lvalue and rvalue references. We've did this for the **refType**
function.

But here we call Forward with explicitly specifying the template type
parameter. When T is an lvalue reference type, the parameter type collapses
to an lvalue reference type in both overloads. But since function
templates are compared before reference collapsing fully erases distinctions
relevant to overload resolution, the call wouldn't be ambiguous, it would
choose the first overload.

To truly support lvalue and rvalue overloads, we have disable the reference
collapsing and force the parameter types to be lvalue and rvalue references:
```cpp
template <typename T>
struct RemoveReference {
	using type = T;
};

template <typename T>
struct RemoveReference <T &> {
	using type = T;
};

template <typename T>
struct RemoveReference <T &&> {
	using type = T;
};

template <typename T>
using RemoveReferenceT = RemoveReference <T>::type;

template <typename T>
T && Forward (RemoveReferenceT <T> & t) {
	return static_cast <T &&> (t);
}

template <typename T>
T && Forward (RemoveReferenceT <T> && t) {
	return static_cast <T &&> (t);
}
```
Here we use RemoveReferenceT to drop the reference-ness of T and make it an
lvalue/rvalue reference type.
Now our forward implementation handles the use case **B** too.

In the second overload static_cast is necessary since t being an identifier
forms an lvalue expression and can't be used to initialize an rvalue expression
without an explicit cast.

The **C** case is a little interesting. This will compile and run successfully:
```cpp
int & x = Forward <int &> (5);
```
We have two templated overloads of Forward. Since we pass an rvalue expression
to the Forward call, the second overload get's chosen. In Forward's static_cast
**t** despite being an **int &&** object forms an lvalue expression being an
identifier. Then Forward returns an lvalue reference to it's **t** parameter
which is destroyed after the Forward call ends.

Let's implement a little verbose class and see what happens when we try to take
an lvalue reference to an rvalue expression with our current Forward
implementation:
```cpp
# include <iostream>



template <typename T>
struct RemoveReference {
	using type = T;
};

template <typename T>
struct RemoveReference <T &> {
	using type = T;
};

template <typename T>
struct RemoveReference <T &&> {
	using type = T;
};

template <typename T>
using RemoveReferenceT = RemoveReference <T>::type;

template <typename T>
T && Forward (RemoveReferenceT <T> & t) {
	return static_cast <T &&> (t);
}

template <typename T>
T && Forward (RemoveReferenceT <T> && t) {
	return static_cast <T &&> (t);
}



struct C {
	C () {
		std::cout << "ctor on " << this << std::endl;
	}

	C (const C &) {
		std::cout << "copy ctor on " << this << std::endl;
	}

	C (C &&) noexcept {
		std::cout << "move ctor on " << this << std::endl;
	}

	C & operator= (const C &) {
		std::cout << "move assign on " << this << std::endl;
		return *this;
	}

	C & operator= (C &&) noexcept {
		std::cout << "move assign on " << this << std::endl;
		return *this;
	}

	~C () {
		std::cout << "dtor on " << this << std::endl;
	}
};



int main () {
	C c;
	C & c1 = Forward <C &> (C ());

	c1 = c;
}
```
The output is:
```
ctor on 0x7fff6d76946e
ctor on 0x7fff6d76946f
dtor on 0x7fff6d76946f
move assign on 0x7fff6d76946f
dtor on 0x7fff6d76946e
```
We have assignment on the C object at 0x7fff6d76946f memory location after
it's deletion. This is called an use-after-free bug.

To prevent it we have to add a static assertion in our rvalue overload of
Forward:
```cpp
template <typename>
struct IsLvalueReference {
	static constexpr bool value = false;
};

template <typename T>
struct IsLvalueReference <T &> {
	static constexpr bool value = true;
};

template <typename T>
struct RemoveReference {
	using type = T;
};

template <typename T>
struct RemoveReference <T &> {
	using type = T;
};

template <typename T>
struct RemoveReference <T &&> {
	using type = T;
};

template <typename T>
using RemoveReferenceT = RemoveReference <T>::type;

template <typename T>
T && Forward (RemoveReferenceT <T> & t) {
	return static_cast <T &&> (t);
}

template <typename T>
T && Forward (RemoveReferenceT <T> && t) {
	static_assert (false == IsLvalueReference <T>::value, "don't use after free");
	return static_cast <T &&> (t);
}
```
When Forward is called with an rvalue expression, we check whether the user
tries to initialize an lvalue reference with the rvalue expression, and if
he tries so, we cause a compile time error. Now the **C** case is satisfied too!

When we use Forward like this:
```cpp
Forward <const T2> (t)
```
Forward's parameter and return type become const references which in case
of **t** being an lvalue expression collapse to const lvalue references and
become const rvalue references in case of **t** being an rvalue expression. Our
implementation satisfies the **D** case.

**E** is satisfied since we do nothing that violates the basic rule in C++
where rvalue/lvalue reference types can be initialized with an expression
of an derived type and with the appropriate value category. **F** is also
satisfied since we use referenced and non-reference variations of the same
base type both for the Forward's parameter and return types.

This is how GNU's STL implements std::forward, except they declare it with the
constexpr and noexcept specifiers.

When we use type traits like RemoveReference, RemoveReferenceT, RefType,
MiniDecay, etc, the result is being processed compile-time, not run-time. The
functions which satisfy C++'s requirements to be evaluated compile-time -
roughly speaking functions which don't use any runtime data - C++ allows to
mark them constexpr so the call is potentially being evaluated compile-time.
In our examples the refType function could be marked constexpr.

Noexcept guarantees that the function call doesn't throw any exceptions.

std::move is simpler. It just casts its argument to an rvalue expression.
It works like this:
```cpp
template <typename T>
constexpr RemoveReferenceT <T> && Move (T && value) noexcept {
	return static_cast <RemoveReferenceT <T> &&> (value);
}
```
Since Move always forms an rvalue expression using it's argument, we don't
need to guard against an lvalue reference being initialized with an rvalue
expression here.
Here our goal isn't to preserve the reference category of the argument. Our goal
is to cast the argument to an rvalue expression.
If we were used T && as a return type of the function, it would collapse
references and produce lvalue expressions in some cases. With RemoveReferenceT
we avoid reference collapsing and force the return type to be an rvalue
reference. We do the same in static_cast too.

## Parameter packs and template recursion
### Parameter packs

Our tuple implementation currently supports fixed two members. That's not
a tuple yet. To support arbitrary number of members of arbitrary types,
we have to use parameter packs.
Consider this example:
```cpp
# include <memory>
# include <string>
# include <vector>

template <typename ... Ts>
void foo (Ts ...) {
}

int main () {
	foo (1, 2);
	foo (1, "2");
	foo (1, 2, 3, 4, 5);
	foo (std::string ("abc"), 2.4, std::make_unique <int> (10));
	foo (std::vector <int> {1, 2, 3}, std::vector <std::string> {"abc", "def"}, 3.14);
	foo ();
}
```

First we declare Ts as a pack of types, which can consist of single or multiple
types or even can be empty.
That's a special syntax called [template parameter pack](https://en.cppreference.com/cpp/language/pack).
In foo's parameter list we use **Ts ... vs** to accept arbitrary number of
arguments of arbitrary types. That's also a special syntax. It's called function
parameter pack. The "type" of the function parameter must be a template
parameter pack. These two functions are invalid:
```cpp
void foo (int ... vs) {}

template <typename T>
void bar (T ... vs) {}
```

C++ provides tools like fold expansion and the ***sizeof ...** operator to work
with parameter packs:
```cpp
# include <iostream>

template <typename ... Ts>
void foo (Ts ... vs) {
	int c = sizeof ... (vs);
	int s = (vs + ...);

	std::cout << "parameter count: " << c << ", sum: " << s << std::endl;
}

int main () {
	foo (1);
	foo (1, 2);
	foo (1, 2, 3);
	foo (1, 2, 3, 4);
	foo (1, 2, 3, 4, 5);
	// foo (); // error inside foo
}
```
Output:
```
parameter count: 1, sum: 1
parameter count: 2, sum: 3
parameter count: 3, sum: 6
parameter count: 4, sum: 10
parameter count: 5, sum: 15
```

Here we use the [sizeof...](https://en.cppreference.com/cpp/language/sizeof...)
operator to get the number of arguments passed. We could use sizeof... on
**Ts** instead:
```cpp
int c = sizeof ... (Ts);
```
Then we calculate the sum of parameters with:
```cpp
int s = (vs + ...);
```
This is a special syntax called [fold
expansion](https://en.cppreference.com/cpp/language/fold). We sum up all the
values inside the function parameter pack.

A special case is when we don't give any argument to foo. **vs** becomes empty
and the **(vs + ...)** fold expression becomes invalid. To handle that case we
can add 0 to the sum in the fold expression:
```cpp
# include <iostream>

template <typename ... Ts>
void foo (Ts ... vs) {
	int c = sizeof ... (vs);
	int s = (vs + ... + 0);

	std::cout << "parameter count: " << c << ", sum: " << s << std::endl;
}

int main () {
	foo ();
}
```
Now when **vs** is empty the fold expression evaluates to 0. Otherwise we add
0 to the sum which doesn't change its value.

### Template recursion

Although we calculate the sum in the simplest way, here's an example on how we
can calculate the sum combining parameter packs with recursion:
```cpp
# include <iostream>

template <typename T, typename ... Ts>
int foo (T v, Ts ... vs) {
	if constexpr (0 == sizeof ... (vs)) {
		return v;
	}
	else {
		return v + foo <Ts ...> (vs ...);
	}
}

int main () {
	std::cout << foo (1) << std::endl;
	std::cout << foo (1, 2) << std::endl;
	std::cout << foo (1, 2, 3) << std::endl;
	std::cout << foo (1, 2, 3, 4) << std::endl;
	std::cout << foo (1, 2, 3, 4, 5) << std::endl;
}
```
Here we separate the first parameter from the rest. That gives the benefit
that when we call the same function passing the rest of the arguments, and that
call itself separates its first parameter from the rest and so on moving toward
the non-recursive call where the parameter pack is empty. **if constexpr**
is an if statement which is evaluated at compile-time.

Inside foo we check whether the parameter pack is empty or not. If it's empty,
we simply return the first parameter. Otherwise we call foo recursively on
the rest of the parameters and add the returned value to the first parameter.

Let's make the code a little verbose and see what happens:
```cpp
# include <iostream>

template <typename T, typename ... Ts>
int foo (T v, Ts ... vs) {
	std::cout << "first param: " << v << ", size of the pack: " << sizeof ... (vs) << std::endl;

	if constexpr (0 == sizeof ... (vs)) {
		return v;
	}
	else {
		return v + foo <Ts ...> (vs ...);
	}
}

int main () {
	int sum = foo (1, 2, 3);
	std::cout << "sum: " << sum << std::endl;
}
```
The output is:
```
first param: 1, size of the pack: 2
first param: 2, size of the pack: 1
first param: 3, size of the pack: 0
sum: 6
```

When we call foo (1, 2, 3), in the first call of foo:
* T = int
* Ts is a pack of int, int
* v = 1
* vs is a pack of 2, 3

since vs isn't empty, we return v + foo <Ts ...> (vs ...).
In that second call of foo:
* T = int
* Ts is a pack of int
* v = 2
* vs is a pack of 3

since vs isn't empty, we call foo again where:
* T = int
* Ts is an empty pack
* v = 3
* vs is an empty pack

and now since **vs** empty, **sizeof ... (vs)** becomes 0 and we return
3 which gets summed up with 2 and returned to the main call where that sum
is summed up with 1 and returned.

### Compile-time if statement

Now let's understand why we've used **if constexpr**. When we call foo, the
compiler generates the appropriate function based on the arguments we've
passed. When we use **if constexpr**, the condition is being evaluated
compile-time and the false branch isn't being compiled.

In the last recursive call of foo the compiler tries to compile the whole
function body, the false branch too where we have a call of foo <> ().

But since we've defined foo as function always having at least one template and
at least one function parameter, compiler tries and doesn't find the foo <> ()
function and gives an error.

When we use **if constexpr**, the false branch in the last recursive call of foo
doesn't get compiled, so we avoid that error.

Without **if constexpr** we could solve that problem just by adding the missing
function:
```cpp
# include <iostream>

template <typename ...>
int foo () { return 0; }

template <typename T, typename ... Ts>
int foo (T v, Ts ... vs) {
	std::cout << "first param: " << v << ", size of the pack: " << sizeof ... (vs) << std::endl;

	if (0 == sizeof ... (vs)) {
		return v;
	}
	else {
		return v + foo <Ts ...> (vs ...);
	}
}

int main () {
	int sum = foo (1, 2, 3);
	std::cout << "sum: " << sum << std::endl;
}
```

Now let's try to use foo's returned value in a place where a compile-time
expression is required, for example when we initialize a static array:
```cpp
# include <iostream>

template <typename ...>
int foo () { return 0; }

template <typename T, typename ... Ts>
int foo (T v, Ts ... vs) {
	std::cout << "first param: " << v << ", size of the pack: " << sizeof ... (vs) << std::endl;

	if (0 == sizeof ... (vs)) {
		return v;
	}
	else {
		return v + foo <Ts ...> (vs ...);
	}
}

int main () {
	if constexpr (0 < foo (1, 2, 3)) {
		std::cout << "positive" << std::endl;
	}
}
```
This gives an error: "Constexpr if condition is not a constant expression".
That's because foo doesn't get evaluated compile-time. Even if we mark it
constexpr, we'll have the same error. constexpr functions are **potentially**
evaluated compile-time. Since we have an std::cout expression in foo, even
marking foo constexpr doesn't make foo to evaluate compile-time, because
std::cout does a run-time job and can't be evaluated compile time.

If we remove the std::cout expression too, the code would compile successfully:
```cpp
# include <iostream>
# include <type_traits>

template <typename T, typename ... Ts>
constexpr std::common_type_t <T, Ts ...> foo (T v, Ts ... vs) {
	if constexpr (0 == sizeof ... (vs)) {
		return v;
	}
	else {
		return v + foo <Ts ...> (vs ...);
	}
}

int main () {
	if constexpr (0 < foo (1, 2, 3)) {
		std::cout << "positive" << std::endl;
	}

	std::cout << foo (1, 2.2f, 3.3) << std::endl;
}
```
Output:
```
positive
6.5
```

Here we use [std::common_type_t](https://cppreference.com/cpp/types/common_type)
to avoid the fixed return type.

### Template recursion with structs

We can use parameter packs also with structs. We can rewrite our sum function
with structs:
```cpp
# include <iostream>

template <int ...>
struct Foo;

template <int V, int ... Vs>
struct Foo <V, Vs ...> {
	static constexpr int value = V + Foo <Vs ...>::value;
};

template <>
struct Foo <> {
	static constexpr int value = 0;
};

int main () {
	std::cout << Foo <1, 2, 3>::value << std::endl;
}
```
Here we first declare Foo as a struct taking zero or more integers as
template parameters. Then we specialize the case where we have at least
one integer in template parameters. Since we didn't use any branching here
to avoid the evaluation of Foo <> case, we've specialized that case too.
Since neither specialization's covered argument set is a subset of another's,
and specializations' covered argument sets must be a subsets of the primary
template's covered argument set, we've declared the primary template having
template parameters covering the union of the covered argument sets of
both specializations: any number of integer arguments. In each case one of
the specializations is more specialized, more strict match for the arguments
passed than the primary template, so the primary template never gets chosen
over the specializations and can be empty.

### Recursions done right

When implementing a recursion always remember these rules quoted from *"Data
Structures and Algorithm Analysis in C++ (4th ed.) - Mark Allen Weiss"*:
1. Base cases. You must always have some base cases, which can be solved without
recursion.
2. Making progress. For the cases that are to be solved recursively, the
recursive call must always be to a case that makes progress toward a base case.
3. Design rule. Assume that all the recursive calls work.
4. Compound interest rule. Never duplicate work by solving the same instance
of a problem in separate recursive calls.

Here the base case is **Foo <>** and we're making progress at each recursive
call reducing the parameter's count by one.

Calculating n'th Fibonacci number is a little tricky. An obvious implementation
would be:
```cpp
# include <iostream>

template <unsigned N>
struct Fib {
	static constexpr unsigned value = Fib <N - 1>::value + Fib <N - 2>::value;
};

template <>
struct Fib <0> {
	static constexpr unsigned value = 0;
};

template <>
struct Fib <1> {
	static constexpr unsigned value = 1;
};

int main () {
	std::cout << Fib <0>::value << std::endl;
	std::cout << Fib <1>::value << std::endl;
	std::cout << Fib <2>::value << std::endl;
	std::cout << Fib <3>::value << std::endl;
	std::cout << Fib <4>::value << std::endl;
	std::cout << Fib <5>::value << std::endl;
	std::cout << Fib <6>::value << std::endl;
	std::cout << Fib <7>::value << std::endl;
	std::cout << Fib <8>::value << std::endl;
	std::cout << Fib <9>::value << std::endl;
}
```
The output is:
```
0
1
1
2
3
5
8
13
21
34
```
The implementation is trivial. We define the Fib templated struct with a
primary specialization of **Fib<N> = Fib<N - 1> + F<N - 2>**. Then we specialize
the **N = 0** and **N = 1** cases. Since they are more specialized for template
parameters 0 and 1, everything works fine.

But we've violated the 4th rule: in **Fib<N>** the value of **Fib<N - 2>**
is the same as the value of **Fib<M - 1>** in **Fib<M = N - 1>**. For example
in **Fib<9>** we calculate **Fib<8> + Fib<7>**. But we calculate **Fib<7>**
also in **Fib<8> = Fib<7> + Fib<6>**. And furthermore we calculate **Fib <9>**
in **Fib<10>** and **Fib<11>**, hence we calculate **Fib<7>** four times to
calculate **Fib<11>**, and this number grows exponentially.

To avoid calculating values multiple times we can implement Fib like this:
```cpp
template <unsigned N>
struct Fib {
	using prev = Fib <N - 1>;
	static constexpr unsigned value = prev::value + prev::prev_value;
	static constexpr unsigned prev_value = prev::value;
};

template <>
struct Fib <0> {
	static constexpr unsigned value = 0;
	static constexpr unsigned prev_value = 1;
};
```
Note that 1 isn't the previous value of Fib<0>, we use it as a trick to help to
calculate Fib<1>. Here **Fib<n>** calculates only **Fib<n - 1>**, so nothing is
calculated twice.

### C++ utilities to work with templates

An useful property of templated structs is that we can capture one struct's
parameters inside another one:
```cpp
# include <iostream>

template <int ...>
struct Foo;

template <int V, int ... Vs>
struct Foo <V, Vs ...> {
	static constexpr int value = V + Foo <Vs ...>::value;
};

template <>
struct Foo <> {
	static constexpr int value = 0;
};

template <typename>
struct Bar;

template <int ... Vs>
struct Bar <Foo <Vs ...>> {
	static constexpr int value = (Vs + ... + 0);
};

template <typename>
struct FooParamCount;

template <int ... Vs>
struct FooParamCount <Foo <Vs ...>> {
	static constexpr int value = sizeof ... (Vs);
};

int main () {
	std::cout << Foo <1, 2, 3>::value << std::endl;
	std::cout << Bar <Foo <1, 2, 3>>::value << std::endl;
	std::cout << FooParamCount <Foo <1, 2, 3, 4, 5>>::value << std::endl;
}
```
Here Bar is a templated struct specialized only for **Foo <...>**. We've
specialized Bar such a way that we have access to Foo's template parameters
inside Bar.
Bar uses a fold expression to calculate Foo's value without a recursion and
FooParamCount calculates Foo's parameter count with the **sizeof ...** operator.
The output is:
```
6
6
5
```

### Generating parameter packs with inheritance recursion

We can generate a parameter pack for example to calculate the sum of the numbers
1 to N:
```cpp
# include <iostream>
# include <utility>

template <unsigned N, typename = std::make_integer_sequence <unsigned, N>>
struct Sum;

template <unsigned N, unsigned ... Ns>
struct Sum <N, std::integer_sequence <unsigned, Ns ...>> {
	static constexpr unsigned value = (Ns + ... + N);
};

int main () {
	std::cout << Sum <0>::value << std::endl;
	std::cout << Sum <1>::value << std::endl;
	std::cout << Sum <2>::value << std::endl;
	std::cout << Sum <3>::value << std::endl;
	std::cout << Sum <4>::value << std::endl;
	std::cout << Sum <5>::value << std::endl;
	std::cout << Sum <6>::value << std::endl;
	std::cout << Sum <7>::value << std::endl;
	std::cout << Sum <8>::value << std::endl;
	std::cout << Sum <9>::value << std::endl;
}
```
Here when we use **Sum <N>**, the primary template initializes the second
parameter with **std::make_integer_sequence <unsigned, N>>** which "returns"
**std::integer_sequence <unsigned, 0, 1, ... N - 1>**. Then the partial
specialization becomes chosen since it's more specialized for unsigned and
std::integer_sequence parameters. Then we take the integer sequence and sum
up with a fold expression and add N since the sequence consists of 0, 1,
... N - 1. We could increase each value in fold by one instead:
```cpp
template <unsigned N, typename = std::make_integer_sequence <unsigned, N>>
struct Sum;

template <unsigned N, unsigned ... Ns>
struct Sum <N, std::integer_sequence <unsigned, Ns ...>> {
	static constexpr unsigned value = ((Ns + 1) + ... + 0);
};
```

Now let's understand how std::integer_sequence and std::make_integer_sequence
work. std::integer_sequence can be replaced with an empty struct containing
integers as parameters:
```cpp
template <typename T, T ... Vs>
struct IntegerSequence {};
```
This struct stores its data in its parameters!

Then we need an std::make_integer_sequence alternative which "returns" an
IntegerSequence. But note that std::make_integer_sequence <...> isn't a
function call. It's a type alias to std::integer_sequence template. We can
implement an alternative like this:
```cpp
template <typename T, std::size_t N, T ... Ns>
struct MakeIntegralSequenceImpl : MakeIntegralSequenceImpl <T, N - 1, Ns ..., N - 1> {};

template <typename T, T ... Ns>
struct MakeIntegralSequenceImpl <T, 0, Ns ...> {
	using type = IntegerSequence <T, Ns ...>;
};

template <typename T, std::size_t N>
using MakeIntegralSequence = MakeIntegralSequenceImpl <T, N>::type;
```
Here in MakeIntegralSequenceImpl we have inheritance recursion. The base case
is the N=0 specialization. Each recursive step in the inheritance evaluation
decreases N by one making a progress toward the base case. In each step of
the recursion we also add the sequential number at the end of the template
parameter pack. The base case defines a type alias which stores all of the
generated numbers in IntegerSequence's parameter list.
Then we have a type alias for MakeIntegralSequenceImpl as we've done for
MiniDecay.

Now the complete example would be:
```cpp
# include <iostream>
# include <utility>



template <typename T, T ... vs>
struct IntegerSequence {};

template <typename T, std::size_t N, T ... Ns>
struct MakeIntegralSequenceImpl : MakeIntegralSequenceImpl <T, N - 1, Ns ..., N - 1> {};

template <typename T, T ... Ns>
struct MakeIntegralSequenceImpl <T, 0, Ns ...> {
	using type = IntegerSequence <T, Ns ...>;
};

template <typename T, std::size_t N>
using MakeIntegralSequence = MakeIntegralSequenceImpl <T, N>::type;



template <unsigned N, typename = MakeIntegralSequence <unsigned, N>>
struct Sum;

template <unsigned N, unsigned ... Ns>
struct Sum <N, IntegerSequence <unsigned, Ns ...>> {
	static constexpr unsigned value = ((1 + Ns) + ... + 0);
};

int main () {
	std::cout << Sum <0>::value << std::endl;
	std::cout << Sum <1>::value << std::endl;
	std::cout << Sum <2>::value << std::endl;
	std::cout << Sum <3>::value << std::endl;
	std::cout << Sum <4>::value << std::endl;
	std::cout << Sum <5>::value << std::endl;
	std::cout << Sum <6>::value << std::endl;
	std::cout << Sum <7>::value << std::endl;
	std::cout << Sum <8>::value << std::endl;
	std::cout << Sum <9>::value << std::endl;

	[] <unsigned ... Ns> (std::integer_sequence <unsigned, Ns ...>) -> void {
		((std::cout << Ns << ' '), ...) << std::endl;
	} (std::make_integer_sequence <unsigned, 9> {});
}
```
The output is:
```
0
1
3
6
10
15
21
28
36
45
0 1 2 3 4 5 6 7 8
```
At the end of the main function we have a templated lambda which helps to print
the std::integer_sequence.

We can do a lot of fun stuff with templates, but let's stay on topic, we need a
tuple!

## The tuple. Finally !!

When we started to implement a tuple before learning about parameter packs and
template recursion, we ended up with this not-tuple-yet implementation:
```cpp
# include <iostream>
# include <memory>
# include <type_traits>
# include <utility>

template <typename T>
struct S1 {
	T value;

	template <typename T1>
	S1 (T1 && t)
		: value (std::forward <T1> (t))
	{}
};

template <typename T, typename U>
struct S2 : S1 <T> {
	U value;

	template <typename T1, typename U1>
	S2 (T1 && t, U1 && u)
		: S1 <T> (std::forward <T1> (t))
		, value (std::forward <U1> (u))
	{}
};

template <typename T, typename U>
S2 (T, U) -> S2 <T, U>;

int main () {
	S2 s (10, std::make_unique <int> (10));
	std::cout << * s.value.get () << std::endl;
	std::cout << static_cast <S1 <int> &> (s).value << std::endl;
}
```
Now the full implementation is trivial. We have to take types and values with
parameter packs and store in the inheritance hierarchy with an inheritance
recursion:
```cpp
# include <iostream>
# include <string>
# include <utility>

template <typename ...>
struct Tuple;

template <typename T, typename ... Ts>
struct Tuple <T, Ts ...> : Tuple <Ts ...> {
	T value;

	template <typename U, typename ... Us>
	Tuple (U && u, Us && ... us)
		: Tuple <Ts ...> (std::forward <Us> (us) ...)
		, value (std::forward <U> (u))
	{}
};

template <> struct Tuple <> {};

template <typename ... Ts>
Tuple (Ts ...) -> Tuple <Ts ...>;

int main () {
	Tuple <int, double, std::string> t (10, 20.30, "abc");

	std::cout << t.value << std::endl;
	std::cout << static_cast <Tuple <double, std::string> &> (t).value << std::endl;
	std::cout << static_cast <Tuple <std::string> &> (t).value << std::endl;
}
```
The output is:
```
10
20.3
abc
```
Here our recursive base case is **Tuple <>** and each recursive step of
inheritance makes progress toward the base case decreasing the size of
the template parameter pack by one.

We store the members of the tuple in the inheritance hierarchy and then
access them with static cast. STL has std::get to work with std::tuple:
```cpp
# include <iostream>
# include <tuple>

int main () {
	std::tuple t (10, 20.30, "abc");

	std::cout << std::get <0> (t) << std::endl;
	std::cout << std::get <1> (t) << std::endl;
	std::cout << std::get <2> (t) << std::endl;

	std::get <1> (t) = 40.50;
	std::cout << std::get <1> (t) << std::endl;
}
```
The output is:
```
10
20.3
abc
40.5
```
The implementation of std::get is a little tricky. std::get takes the tuple
member index and returns a reference to the member. We first have to obtain the
type of the member at the index:
```cpp
template <std::size_t N, typename T, typename ... Ts>
struct NthType : NthType <N - 1, Ts ...> {};

template <typename T, typename ... Ts>
struct NthType <0, T, Ts ...> {
	using type = T;
};
```
Then with a recursive function we can return an lvalue reference to the member:
```cpp
template <std::size_t N, typename T, typename ... Ts>
constexpr NthType <N, T, Ts ...>::type & getTupleMember (Tuple <T, Ts ...> & tuple) noexcept {
	if constexpr (0 == N) {
		return tuple.value;
	}
	else {
		return getTupleMember <N - 1> (static_cast <Tuple <Ts ...> &> (tuple));
	}
}
```
Here our base case of the recursion is N = 0. When N = 0 we return the value
member of the appropriate inheritance level. Otherwise we cast the tuple
to an lvalue reference of the next inheritance level and decrease N by 1
moving toward the base case. Since the getTupleMember function does only
static_cast and member access, we mark it as noexcept. Here getTupleMember
function solves two different tasks: it calculates the N'th member type then
provides an access to it. We can separate these two tasks and move the N'th
inheritance level tuple type calculation outside the getTupleMember function:
```cpp
template <std::size_t N, typename T, typename ... Ts>
struct NthInheritanceLevelTuple : NthInheritanceLevelTuple <N - 1, Ts ...> {};

template <typename T, typename ... Ts>
struct NthInheritanceLevelTuple <0, T, Ts ...> {
	using type = Tuple <T, Ts ...>;
};

template <std::size_t N, typename T, typename ... Ts>
constexpr NthType <N, T, Ts ...>::type & getTupleMember (Tuple <T, Ts ...> & tuple) noexcept {
	return static_cast <NthInheritanceLevelTuple <N, T, Ts ...>::type &> (tuple).value;
}
```
And the whole example becomes:
```cpp
# include <cstddef>
# include <iostream>
# include <string>
# include <utility>

template <typename ...>
struct Tuple;

template <typename T, typename ... Ts>
struct Tuple <T, Ts ...> : Tuple <Ts ...> {
	T value;

	template <typename U, typename ... Us>
	Tuple (U && u, Us && ... us)
		: Tuple <Ts ...> (std::forward <Us> (us) ...)
		, value (std::forward <U> (u))
	{}
};

template <> struct Tuple <> {};

template <typename ... Ts>
Tuple (Ts ...) -> Tuple <Ts ...>;

template <std::size_t N, typename T, typename ... Ts>
struct NthType : NthType <N - 1, Ts ...> {};

template <typename T, typename ... Ts>
struct NthType <0, T, Ts ...> {
	using type = T;
};

template <std::size_t N, typename T, typename ... Ts>
struct NthInheritanceLevelTuple : NthInheritanceLevelTuple <N - 1, Ts ...> {};

template <typename T, typename ... Ts>
struct NthInheritanceLevelTuple <0, T, Ts ...> {
	using type = Tuple <T, Ts ...>;
};

template <std::size_t N, typename T, typename ... Ts>
constexpr NthType <N, T, Ts ...>::type & getTupleMember (Tuple <T, Ts ...> & tuple) noexcept {
	return static_cast <NthInheritanceLevelTuple <N, T, Ts ...>::type &> (tuple).value;
}

int main () {
	Tuple <int, double, std::string> t (10, 20.30, "abc");

	std::cout << getTupleMember <0> (t) << std::endl;
	std::cout << getTupleMember <1> (t) << std::endl;
	std::cout << getTupleMember <2> (t) << std::endl;
	getTupleMember <1> (t) = 40.50;
	std::cout << getTupleMember <1> (t) << std::endl;

	// std::cout << getTupleMember <0> (Tuple (1)) << std::endl; // error
}
```
Our getTupleMember function takes a reference to the tuple and returns a
reference to the member. To be able to work with rvalue tuples, we have to
overload the getTupleMember function to take const lvalue references:
```cpp
# include <cstddef>
# include <iostream>
# include <string>
# include <utility>

template <typename ...>
struct Tuple;

template <typename T, typename ... Ts>
struct Tuple <T, Ts ...> : Tuple <Ts ...> {
	T value;

	template <typename U, typename ... Us>
	Tuple (U && u, Us && ... us)
		: Tuple <Ts ...> (std::forward <Us> (us) ...)
		, value (std::forward <U> (u))
	{}
};

template <> struct Tuple <> {};

template <typename ... Ts>
Tuple (Ts ...) -> Tuple <Ts ...>;

template <std::size_t N, typename T, typename ... Ts>
struct NthType : NthType <N - 1, Ts ...> {};

template <typename T, typename ... Ts>
struct NthType <0, T, Ts ...> {
	using type = T;
};

template <std::size_t N, typename T, typename ... Ts>
struct NthInheritanceLevelTuple : NthInheritanceLevelTuple <N - 1, Ts ...> {};

template <typename T, typename ... Ts>
struct NthInheritanceLevelTuple <0, T, Ts ...> {
	using type = Tuple <T, Ts ...>;
};

template <std::size_t N, typename T, typename ... Ts>
constexpr NthType <N, T, Ts ...>::type & getTupleMember (Tuple <T, Ts ...> & tuple) noexcept {
	return static_cast <NthInheritanceLevelTuple <N, T, Ts ...>::type &> (tuple).value;
}

template <std::size_t N, typename T, typename ... Ts>
constexpr const NthType <N, T, Ts ...>::type & getTupleMember (const Tuple <T, Ts ...> & tuple) noexcept {
	return static_cast <const NthInheritanceLevelTuple <N, T, Ts ...>::type &> (tuple).value;
}

int main () {
	Tuple <int, double, std::string> t (10, 20.30, "abc");

	std::cout << getTupleMember <0> (t) << std::endl;
	std::cout << getTupleMember <1> (t) << std::endl;
	std::cout << getTupleMember <2> (t) << std::endl;
	getTupleMember <1> (t) = 40.50;
	std::cout << getTupleMember <1> (t) << std::endl;

	std::cout << getTupleMember <0> (Tuple (1)) << std::endl;
}
```

Now let's analyze a little example to see how we can make our code cleaner:
```cpp
# include <iostream>

struct S { int value = 10; };
struct Q { int value = 20; };

template <typename T>
int getValue (const T & t) {
	return t.value;
}

int main () {
	S s;
	Q q;

	std::cout << getValue (s) << std::endl;
	std::cout << getValue (q) << std::endl;
}
```
Here we have two structs and a template function which prints the value member
of the argument. This function works with both structs. Now let's see what
happens here:
```cpp
# include <iostream>

struct S {
	int value = 10;

	template <typename T>
	friend int getValue (const T & t) {
		return t.value;
	}
};
struct Q { int value = 20; };

int main () {
	S s;
	Q q;

	std::cout << getValue (s) << std::endl;
	// std::cout << getValue (q) << std::endl; // error
}
```
Here we've moved getValue inside the struct S. But it's not a member function
(method), it's a regular friend function of S which is visible only when
the argument is type of S. In case of the Q argument the function isn't
visible, hence we've got an error. This is a property of [argument dependent
lookup](https://en.cppreference.com/cpp/language/adl).

We can move our getTupleMember function inside the tuple struct like this:
```cpp
# include <cstddef>
# include <iostream>
# include <string>
# include <utility>

template <typename ...>
struct Tuple;

template <std::size_t N, typename T, typename ... Ts>
struct NthType : NthType <N - 1, Ts ...> {};

template <typename T, typename ... Ts>
struct NthType <0, T, Ts ...> {
	using type = T;
};

template <std::size_t N, typename T, typename ... Ts>
struct NthInheritanceLevelTuple : NthInheritanceLevelTuple <N - 1, Ts ...> {};

template <typename T, typename ... Ts>
struct NthInheritanceLevelTuple <0, T, Ts ...> {
	using type = Tuple <T, Ts ...>;
};

template <typename T, typename ... Ts>
struct Tuple <T, Ts ...> : Tuple <Ts ...> {
	template <typename U, typename ... Us>
	Tuple (U && u, Us && ... us)
		: Tuple <Ts ...> (std::forward <Us> (us) ...)
		, value (std::forward <U> (u))
	{}

	template <std::size_t N, typename U, typename ... Us>
	constexpr friend NthType <N, U, Us ...>::type & getTupleMember (Tuple <U, Us ...> & tuple) noexcept;

	template <std::size_t N, typename U, typename ... Us>
	constexpr friend const NthType <N, U, Us ...>::type & getTupleMember (const Tuple <U, Us ...> & tuple) noexcept;

private:
	T value;
};

template <> struct Tuple <> {
	template <std::size_t N, typename U, typename ... Us>
	constexpr friend NthType <N, U, Us ...>::type & getTupleMember (Tuple <U, Us ...> & tuple) noexcept {
		return static_cast <NthInheritanceLevelTuple <N, U, Us ...>::type &> (tuple).value;
	}

	template <std::size_t N, typename U, typename ... Us>
	constexpr friend const NthType <N, U, Us ...>::type & getTupleMember (const Tuple <U, Us ...> & tuple) noexcept {
		return static_cast <const NthInheritanceLevelTuple <N, U, Us ...>::type &> (tuple).value;
	}
};

template <typename ... Ts>
Tuple (Ts ...) -> Tuple <Ts ...>;

int main () {
	Tuple <int, double, std::string> t (10, 20.30, "abc");

	std::cout << getTupleMember <0> (t) << std::endl;
	std::cout << getTupleMember <1> (t) << std::endl;
	std::cout << getTupleMember <2> (t) << std::endl;
	getTupleMember <1> (t) = 40.50;
	std::cout << getTupleMember <1> (t) << std::endl;

	std::cout << getTupleMember <0> (Tuple (1)) << std::endl;
}
```
Now getTupleMember template function is available only when we're using it with
an argument of the templated Tuple type. In the Tuple <> specialization we're
defining the getTupleMember templated function. Being a friend function of
the Tuple <> struct it can access Tuple <> 's private members, but friendship
isn't an inherited property in C++. Hence we declare these functions as
friend functions in the other specialization of Tuple where we store data,
and make that data private since we already have a function to access it.

And now when everything seems to be perfect we have a big problem. Guess what
happens here:
```cpp
int main () {
	Tuple t (10, 20.30, "abc");
	Tuple t2 = t;
}
```
The compiler tries to copy-construct the Tuple **t2** from **t**, but in
Tuple we have a templated constructor which matches the signature of the copy
constructor and acts like an explicitly defined one hiding the implicitly
generated copy constructor. Then in our templated constructor both the
parent constructor call and the value initialization fail because the parent
constructor expects two arguments because explicitly declared constructor
removes the implicitly generated default constructor, and std::forward in
the value initialization excepts it's type to be a cv/ref-qualified version
of int. We're passing no arguments to the parent constructor call and trying
to forward the other Tuple as int.

To avoid this problem we have to limit the scope of our templated constructor.

Tuple can't have a member of the same type as the Tuple, because in that case
that member tuple would have a member of the same type and so on until infinity.
This would cause infinitely deep instantiation of the Tuple. So we can
explicitly prevent our constructor from taking arguments of its type:
```cpp
template <typename U, typename ... Us>
Tuple (U && u, Us && ... us)
	requires (false == std::is_same_v <std::remove_cvref_t <U>, Tuple>)
	: Tuple <Ts ...> (std::forward <Us> (us) ...)
	, value (std::forward <U> (u))
{}
```

### The requires clause

This is a feature introduced in C++20. It is an additional "clause" in
a template declaration that expresses under what condition the constrained
template is supposed to work. Here we use it to disable our constructor to act
like a copy or move constructor.

I'll expand this section later. Currently you can use these references to learn
about the requires clause and more:
* [Requires-clause - Andrzej's C++ blog](https://akrzemi1.wordpress.com/2020/03/26/requires-clause/)
* [Ordering by constraints - Andrzej's C++ blog](https://akrzemi1.wordpress.com/2020/05/07/ordering-by-constraints/)
* [Concepts vs type traits - Andrzej's C++ blog](https://akrzemi1.wordpress.com/2025/05/24/concepts-vs-type-traits/)
* [Your own type predicate - Andrzej's C++ blog](https://akrzemi1.wordpress.com/2017/12/02/your-own-type-predicate/)

### Structured bindings
STL supports structured bindings for std::tuple. This example demonstrates it:
```cpp
# include <iostream>
# include <tuple>

int main () {
	std::tuple t (1, 2.3, "def");

	{
		auto & [a, b, c] = t;
		std::cout << a << ", " << b << ", " << c << std::endl;
		b = 222;
	}

	{
		auto [a, b, c] = t;

		std::cout << a << ", " << b << ", " << c << std::endl;
	}
}
```
Here we "unpack" tuple's members into distinct variables. The first time we take
references to the members and modify a member with a reference. The second time
we just copy the member values into our variables. The syntax we've used to do
it is called a [structured binding](https://en.cppreference.com/cpp/language/structured_binding).
The output is:
```
1, 2.3, def
1, 222, def
```

To enable structured bindings for our Tuple struct we need three things:
* **get function for our Tuple struct discoverable via argument dependent
lookup which enables us to access the tuple members** - we have just to
rename our getTupleMember function to "get"
* **a specialization of std::tuple_size struct to return the tuple member
count** - we can use the **sizeof ...** operator here
* **a specialization of std::tuple_element struct which enables access to
N'th tuple element type through the member alias type** - we can use our
NthType templated struct here

We can see how C++ interprets these structured bindings with
[cppinsights](https://cppinsights.io/):
```cpp
#include <iostream>
#include <tuple>

int main()
{
	std::tuple<int, double, const char *> t = std::tuple<int, double, const char *>(1, 2.2999999999999998, "def");
	{
		std::tuple<int, double, const char *> & __t8 = t;
		int & a = std::get<0UL>(__t8);
		double & b = std::get<1UL>(__t8);
		const char *& c = std::get<2UL>(__t8);
		std::operator<<(std::operator<<(std::operator<<(std::cout.operator<<(a), ", ").operator<<(b), ", "), c).operator<<(std::endl);
		b = 222;
	};
	{
		std::tuple<int, double, const char *> __t14 = std::tuple<int, double, const char *>(t);
		int && a = std::get<0UL>(static_cast<std::tuple<int, double, const char *> &&>(__t14));
		double && b = std::get<1UL>(static_cast<std::tuple<int, double, const char *> &&>(__t14));
		const char *&& c = std::get<2UL>(static_cast<std::tuple<int, double, const char *> &&>(__t14));
		std::operator<<(std::operator<<(std::operator<<(std::cout.operator<<(a), ", ").operator<<(b), ", "), c).operator<<(std::endl);
	};
	return 0;
}
```
Turns out that we need a get function overload accepting rvalue references too.

If you use NeoVim there's a [great
extension](https://github.com/GasparVardanyan/insights.nvim) to work with
local and remote instances of cppinsights.

The implementation is trivial. Let's first implement the second and the third
requirements:
```cpp
namespace std {
template <typename ... Ts>
struct tuple_size <Tuple <Ts ...>>
	: std::integral_constant <std::size_t, sizeof ... (Ts)> {};

template <std::size_t N, typename ... Ts>
struct tuple_element <N, Tuple <Ts ...>> {
	using type = NthType <N, Ts ...>::type;
};
}
```

Then after renaming the getTupleMember function and adding the rvalue reference
overload we'll have:
```cpp
# include <cstddef>
# include <iostream>
# include <utility>

template <typename ...>
struct Tuple;

template <std::size_t N, typename T, typename ... Ts>
struct NthType : NthType <N - 1, Ts ...> {};

template <typename T, typename ... Ts>
struct NthType <0, T, Ts ...> {
	using type = T;
};

template <std::size_t N, typename T, typename ... Ts>
struct NthInheritanceLevelTuple : NthInheritanceLevelTuple <N - 1, Ts ...> {};

template <typename T, typename ... Ts>
struct NthInheritanceLevelTuple <0, T, Ts ...> {
	using type = Tuple <T, Ts ...>;
};

template <typename T, typename ... Ts>
struct Tuple <T, Ts ...> : Tuple <Ts ...> {
	template <typename U, typename ... Us>
	Tuple (U && u, Us && ... us)
		requires (false == std::is_same_v <std::remove_cvref_t <U>, std::remove_cvref_t <Tuple>>)
		: Tuple <Ts ...> (std::forward <Us> (us) ...)
		, value (std::forward <U> (u))
	{}

	template <std::size_t N, typename U, typename ... Us>
	constexpr friend NthType <N, U, Us ...>::type & get (Tuple <U, Us ...> & tuple) noexcept;

	template <std::size_t N, typename U, typename ... Us>
	constexpr friend const NthType <N, U, Us ...>::type & get (const Tuple <U, Us ...> & tuple) noexcept;

	template <std::size_t N, typename U, typename ... Us>
	constexpr friend NthType <N, U, Us ...>::type && get (Tuple <U, Us ...> && tuple) noexcept;

private:
	T value;
};

template <> struct Tuple <> {
	template <std::size_t N, typename U, typename ... Us>
	constexpr friend NthType <N, U, Us ...>::type & get (Tuple <U, Us ...> & tuple) noexcept {
		return static_cast <NthInheritanceLevelTuple <N, U, Us ...>::type &> (tuple).value;
	}

	template <std::size_t N, typename U, typename ... Us>
	constexpr friend const NthType <N, U, Us ...>::type & get (const Tuple <U, Us ...> & tuple) noexcept {
		return static_cast <const NthInheritanceLevelTuple <N, U, Us ...>::type &> (tuple).value;
	}

	template <std::size_t N, typename U, typename ... Us>
	constexpr friend NthType <N, U, Us ...>::type && get (Tuple <U, Us ...> && tuple) noexcept {
		return static_cast <NthInheritanceLevelTuple <N, U, Us ...>::type &&> (tuple).value;
	}
};

template <typename ... Ts>
Tuple (Ts ...) -> Tuple <Ts ...>;

namespace std {
template <typename ... Ts>
struct tuple_size <Tuple <Ts ...>>
	: std::integral_constant <std::size_t, sizeof ... (Ts)> {};

template <std::size_t N, typename ... Ts>
struct tuple_element <N, Tuple <Ts ...>> {
	using type = NthType <N, Ts ...>::type;
};
}

int main () {
	Tuple t (1, 2.3, "def");

	{
		auto & [a, b, c] = t;
		std::cout << a << ", " << b << ", " << c << std::endl;
		b = 222;
	}

	{
		auto [a, b, c] = t;

		std::cout << a << ", " << b << ", " << c << std::endl;
	}
}
```
The output is:
```
1, 2.3, def
1, 222, def
```
Note that in the rvalue overload version we cast the tuple itself to an rvalue
expression and take it's member. Member access on an xvalue expression of a
struct type yields an xvalue reference to the member. Here the tuple parameter
when casted to an rvalue reference produces an xvalue.

The other way we could implement the rvalue overload of the get function
can be more intuitive:
```cpp
template <std::size_t N, typename U, typename ... Us>
constexpr friend NthType <N, U, Us ...>::type && get (Tuple <U, Us ...> && tuple) noexcept {
	return std::move (static_cast <NthInheritanceLevelTuple <N, U, Us ...>::type &> (tuple).value);
}
```
Here since we need an access to the actual tuple member, we cast the tuple
parameter to an lvalue reference of the appropriate inheritance level type
to access the correct base subobject, then explicitly convert the member to
an xvalue using std::move.
