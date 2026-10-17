#include <cstdio>
#include <cstdlib>
#include <cstdarg>
namespace swift { namespace threading {
[[noreturn]] void fatal(const char *fmt, ...) { va_list a; va_start(a, fmt); vfprintf(stderr, fmt, a); va_end(a); abort(); }
} }
