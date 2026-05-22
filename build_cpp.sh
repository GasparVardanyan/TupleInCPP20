#!/usr/bin/env bash

clang++ --std=c++20 -pedantic-errors -Werror=pedantic -Wall -Wextra test.cpp && ./a.out
