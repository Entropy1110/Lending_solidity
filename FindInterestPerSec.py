def f(x):
    return (1 + x)**129600000 - (1 + 0.001)**1500

def bisection_method(a, b, tol):
    while (b - a) / 2.0 > tol:
        midpoint = (a + b) / 2.0
        if f(midpoint) == 0:
            return midpoint
        elif f(a) * f(midpoint) < 0:
            b = midpoint
        else:
            a = midpoint
    return (a + b) / 2.0

# 초기 값 설정
a = 0
b = 0.000001

# 오차 허용 범위 (소수 12번째 자리까지)
tolerance = 1e-15

# 근사값 계산
approx_solution = bisection_method(a, b, tolerance)

# 결과 출력
print(f"x ≈ {approx_solution:.33f}")

# x ≈ 0.000000011568290181457995110458397