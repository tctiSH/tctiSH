# shellcheck shell=sh
#
# summary: sympy integrates, differentiates and solves: a large pure-Python program, start to end
#
# Python's startup and sympy's import are about half of it, and the algebra the rest.

rm -f /tmp/sympy.out
bench_time -o /tmp/sympy.out run python3 -c '
import sympy as s
x, y = s.symbols("x y")
print(s.integrate(x**3 * s.exp(x) * s.sin(x), x))
print(s.simplify(s.diff(s.atan(s.sqrt(x**2 + 1)) * s.log(x + s.sqrt(x**2 + 1)), x, 3)))
print(s.solve([x**2 + y**2 - 25, x*y - 12], [x, y]))
'
bench_check output "$(bench_digest </tmp/sympy.out)"
